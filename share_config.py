#!/usr/bin/env python3
"""Make every Claude login share one set of instructions, settings, skills and memory.

Each Claude account Token Stats adds gets its own CLAUDE_CONFIG_DIR, so by
default each one has its own instructions, settings, skills and auto-memory.
This links each account's CLAUDE.md, settings.json and skills back to ~/.claude.

Memory goes one step further. Each project's memory folder, in ~/.claude and in
every account, becomes a link to ~/.agents/memory/<project>, so a memory saved
on one login is there on all of them. It can't live in ~/.claude itself:
Claude Code treats everything under ~/.claude as protected and blocks other
logins from writing there. Claude Code also checks the real path behind a link,
so settings.json gets allow rules for both the links and ~/.agents/memory.

It's safe to run any time and does nothing once everything is shared. It adds a
SessionStart hook that runs it with --hook, which also links the memory folder
for the project each session starts in.
"""

import argparse
import fcntl
import filecmp
import json
import os
import re
import shutil
import sys
from dataclasses import dataclass, field
from pathlib import Path

HOME = Path.home()
DEFAULT_MAIN = HOME / ".claude"
DEFAULT_ACCOUNTS = HOME / "Library" / "Application Support" / "Token Stats" / "Accounts"
DEFAULT_SHARED_MEMORY = HOME / ".agents" / "memory"
SHARED_FILES = ("CLAUDE.md", "settings.json")
# Claude Code keeps each login's own claude.ai skills in skills/synced.
PER_ACCOUNT_SKILLS = {"synced"}
INDEX = "MEMORY.md"
INDEX_LINK = re.compile(r"\]\(([^)]+)\)")
HOOK_MARKER = "share-config --hook"


@dataclass
class Report:
    changes: list = field(default_factory=list)
    skipped: list = field(default_factory=list)


def share(main=DEFAULT_MAIN, accounts=DEFAULT_ACCOUNTS, shared_memory=DEFAULT_SHARED_MEMORY,
          current_transcript=None, dry_run=False, hook_command=None):
    main, accounts, shared_memory = Path(main), Path(accounts), Path(shared_memory)
    report = Report()
    roots = [main]
    if accounts.is_dir():
        roots += [a for a in sorted(accounts.glob("claude-*")) if a.is_dir() and not a.is_symlink()]
    _update_settings(main / "settings.json", main, accounts, shared_memory, hook_command, report, dry_run)
    for root in roots:
        if root != main:
            for name in SHARED_FILES:
                _link(main / name, root / name, report, dry_run)
            _share_skills(main / "skills", root / "skills", report, dry_run)
        projects = root / "projects"
        if projects.is_dir():
            for project in sorted(projects.iterdir()):
                if project.is_dir() and not project.is_symlink():
                    _link_memory(project, shared_memory, report, dry_run, create=False)
    if current_transcript:
        project = Path(current_transcript).parent
        if project.parent.name == "projects" and project.parent.parent in roots:
            _link_memory(project, shared_memory, report, dry_run, create=True)
    return report


def _link(target, link, report, dry_run):
    """Point `link` at `target`, but never replace a real file someone made."""
    if not target.exists():
        return
    if link.is_symlink():
        if os.readlink(link) == str(target):
            return
        if link.exists():
            report.skipped.append(f"{link} points somewhere else")
            return
        # A dangling link to an old location is safe to repoint.
    elif link.exists():
        report.skipped.append(f"{link} is a real file, not a link to {target}")
        return
    report.changes.append(f"link {link} -> {target}")
    if not dry_run:
        if link.is_symlink():
            link.unlink()
        os.symlink(target, link)


def _share_skills(main_skills, account_skills, report, dry_run):
    if not main_skills.is_dir():
        return
    if not account_skills.exists():
        report.changes.append(f"create {account_skills}")
        if dry_run:
            return
        account_skills.mkdir(parents=True)
    if account_skills.is_symlink() or not account_skills.is_dir():
        return
    for skill in sorted(main_skills.iterdir()):
        # Hidden folders like .trash hold deleted skills.
        if not skill.name.startswith(".") and skill.name not in PER_ACCOUNT_SKILLS:
            _link(skill, account_skills / skill.name, report, dry_run)
    for entry in sorted(account_skills.iterdir()):
        if entry.is_symlink() and not entry.exists() and os.readlink(entry).startswith(str(main_skills) + os.sep):
            report.changes.append(f"remove {entry} (its skill was deleted)")
            if not dry_run:
                entry.unlink()


def _link_memory(project, shared_memory, report, dry_run, create):
    memory = project / "memory"
    shared = shared_memory / project.name
    if memory.is_symlink():
        if os.readlink(memory) != str(shared):
            report.skipped.append(f"{memory} points somewhere else")
        return
    if memory.exists() and not memory.is_dir():
        report.skipped.append(f"{memory} isn't a folder")
        return
    if not create and not _has_files(memory) and not _has_files(shared):
        # Claude Code makes an empty memory folder in every project, scratch ones
        # included. Linking those would fill ~/.agents/memory with empty folders,
        # so wait until one side has a memory (or a session starts there).
        return
    report.changes.append(f"share {memory} -> {shared}")
    if dry_run:
        return
    shared.mkdir(parents=True, exist_ok=True)
    # At SessionStart, Claude Code hasn't made the project folder yet.
    project.mkdir(parents=True, exist_ok=True)
    if memory.exists():
        _merge_memory(memory, shared, _login_name(project))
        # Anything left is a duplicate of a file already in the shared folder.
        shutil.rmtree(memory)
    os.symlink(shared, memory)


def _login_name(project):
    # projects/<slug> sits in a config folder: ~/.claude or Accounts/claude-N.
    return project.parent.parent.name.lstrip(".")


def _has_files(folder):
    return folder.is_dir() and any(folder.iterdir())


def _merge_memory(source, shared, login_name):
    renamed = {}
    for item in sorted(source.iterdir()):
        if item.name == INDEX:
            continue
        destination = shared / item.name
        if not destination.exists():
            shutil.move(str(item), str(destination))
        elif item.is_file() and destination.is_file() and filecmp.cmp(item, destination, shallow=False):
            continue
        else:
            # Same name, different content: keep both rather than lose a memory.
            new_name = f"{item.stem}-{login_name}{item.suffix}"
            shutil.move(str(item), str(shared / new_name))
            renamed[item.name] = new_name
    _merge_index(source / INDEX, shared / INDEX, renamed)


def _merge_index(source_index, shared_index, renamed):
    if not source_index.exists():
        return
    existing = shared_index.read_text() if shared_index.exists() else ""
    linked = set(INDEX_LINK.findall(existing))
    added = []
    for line in source_index.read_text().splitlines():
        match = INDEX_LINK.search(line)
        if not match:
            continue
        name = match.group(1)
        if name in renamed:
            line = line.replace(f"]({name})", f"]({renamed[name]})", 1)
            name = renamed[name]
        if name not in linked:
            added.append(line)
            linked.add(name)
    if added:
        if existing and not existing.endswith("\n"):
            existing += "\n"
        shared_index.write_text(existing + "\n".join(added) + "\n")


def _rule_path(path):
    """Write a path the way Claude Code permission rules expect it."""
    try:
        return "~/" + str(Path(path).relative_to(HOME))
    except ValueError:
        return "/" + str(path)  # "//abs/path" means an absolute path in a rule


def memory_rules(main, accounts, shared_memory):
    # Claude Code checks a write against both the link and the real folder behind it.
    folders = [
        f"{_rule_path(shared_memory)}/**",
        f"{_rule_path(main)}/projects/*/memory/**",
        f"{_rule_path(accounts)}/*/projects/*/memory/**",
    ]
    return [f"{tool}({folder})" for folder in folders for tool in ("Read", "Edit")]


def _update_settings(settings_path, main, accounts, shared_memory, hook_command, report, dry_run):
    if not settings_path.is_file():
        return
    try:
        settings = json.loads(settings_path.read_text())
    except ValueError:
        report.skipped.append(f"{settings_path} isn't valid JSON, so its memory rules weren't checked")
        return
    changed = False
    allow = settings.setdefault("permissions", {}).setdefault("allow", [])
    for rule in memory_rules(main, accounts, shared_memory):
        if rule not in allow:
            allow.append(rule)
            report.changes.append(f"allow {rule} in {settings_path}")
            changed = True
    if hook_command:
        session_start = settings.setdefault("hooks", {}).setdefault("SessionStart", [])
        commands = [h.get("command", "") for group in session_start for h in group.get("hooks", [])]
        if not any(HOOK_MARKER in command for command in commands):
            session_start.append({"hooks": [{"type": "command", "command": hook_command}]})
            report.changes.append(f"add SessionStart hook to {settings_path}")
            changed = True
    if changed and not dry_run:
        # settings.json is often a link to the shared file; write through it.
        real = settings_path.resolve()
        temporary = real.with_name(real.name + ".share-config.tmp")
        temporary.write_text(json.dumps(settings, indent=2) + "\n")
        os.chmod(temporary, real.stat().st_mode & 0o777)
        os.replace(temporary, real)


def default_hook_command():
    launcher = shutil.which("token-stats") or str(Path(__file__).resolve().parent / "token-stats")
    return f'"{launcher}" {HOOK_MARKER} 2>/dev/null || true'


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dry-run", action="store_true", help="print what would change and change nothing")
    parser.add_argument("--hook", action="store_true", help="run as a SessionStart hook: read its JSON on stdin, print nothing")
    parser.add_argument("--main", type=Path, default=DEFAULT_MAIN, help=argparse.SUPPRESS)
    parser.add_argument("--accounts", type=Path, default=DEFAULT_ACCOUNTS, help=argparse.SUPPRESS)
    parser.add_argument("--shared-memory", type=Path, default=DEFAULT_SHARED_MEMORY, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)

    transcript = None
    if args.hook:
        try:
            transcript = json.load(sys.stdin).get("transcript_path")
        except (ValueError, AttributeError):
            pass

    lock_folder = args.accounts if args.accounts.is_dir() else args.main
    # Sessions starting at the same time would otherwise race to move the same folder.
    with open(lock_folder / ".share-config.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        report = share(args.main, args.accounts, args.shared_memory, current_transcript=transcript,
                       dry_run=args.dry_run, hook_command=None if args.hook else default_hook_command())

    if not args.hook:
        for line in report.changes:
            print(("would " if args.dry_run else "") + line)
        for line in report.skipped:
            print(f"left alone: {line}")
        if not report.changes and not report.skipped:
            print("Every Claude login already shares ~/.claude's instructions, settings and skills, and ~/.agents/memory.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
