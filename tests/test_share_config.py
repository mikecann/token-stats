"""Tests for share_config.py. Run with: python3 -m unittest discover -s tests -p 'test_*.py'"""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import share_config  # noqa: E402

SLUG = "-Users-me-dev-misc"


class ShareConfigTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.main = root / "main"
        self.accounts = root / "Accounts"
        self.shared = root / "agents" / "memory"
        (self.main / "skills" / "voice").mkdir(parents=True)
        (self.main / "skills" / "inventory").mkdir(parents=True)
        (self.main / "skills" / ".trash").mkdir(parents=True)
        (self.main / "CLAUDE.md").write_text("global\n")
        (self.main / "settings.json").write_text('{\n  "model": "opus"\n}\n')
        self.account = self.accounts / "claude-1"
        self.account.mkdir(parents=True)

    def tearDown(self):
        self.tmp.cleanup()

    def run_share(self, **kwargs):
        return share_config.share(main=self.main, accounts=self.accounts, shared_memory=self.shared, **kwargs)

    def memory(self, base, slug=SLUG):
        return base / "projects" / slug / "memory"

    def write_memory(self, folder, files):
        folder.mkdir(parents=True, exist_ok=True)
        for name, text in files.items():
            (folder / name).write_text(text)
        return folder

    def settings(self):
        return json.loads((self.main / "settings.json").read_text())

    def test_links_instructions_settings_and_every_skill(self):
        self.run_share()
        self.assertEqual(os.readlink(self.account / "CLAUDE.md"), str(self.main / "CLAUDE.md"))
        self.assertEqual(os.readlink(self.account / "settings.json"), str(self.main / "settings.json"))
        self.assertEqual(os.readlink(self.account / "skills" / "inventory"), str(self.main / "skills" / "inventory"))
        self.assertFalse((self.account / "skills" / ".trash").exists())

    def test_leaves_a_real_settings_file_alone(self):
        (self.account / "settings.json").write_text('{"own": true}\n')
        report = self.run_share()
        self.assertFalse((self.account / "settings.json").is_symlink())
        self.assertTrue(any("settings.json" in line for line in report.skipped))

    def test_per_account_synced_skills_are_left_alone(self):
        (self.main / "skills" / "synced").mkdir()
        (self.account / "skills" / "synced").mkdir(parents=True)
        report = self.run_share()
        self.assertFalse((self.account / "skills" / "synced").is_symlink())
        self.assertEqual(report.skipped, [])

    def test_removes_skill_links_whose_target_was_deleted(self):
        (self.account / "skills").mkdir()
        os.symlink(self.main / "skills" / "gone", self.account / "skills" / "gone")
        self.run_share()
        self.assertFalse(os.path.lexists(self.account / "skills" / "gone"))

    def test_moves_every_logins_memories_to_the_shared_folder(self):
        self.write_memory(self.memory(self.main), {"MEMORY.md": "- [A](a.md) — main fact\n", "a.md": "a"})
        self.write_memory(self.memory(self.account), {"MEMORY.md": "- [B](b.md) — account fact\n", "b.md": "b"})
        self.run_share()
        shared = self.shared / SLUG
        for login in (self.main, self.account):
            self.assertEqual(os.readlink(self.memory(login)), str(shared))
        self.assertEqual((shared / "a.md").read_text(), "a")
        self.assertEqual((shared / "b.md").read_text(), "b")
        index = (shared / "MEMORY.md").read_text()
        self.assertIn("(a.md)", index)
        self.assertIn("(b.md)", index)

    def test_identical_files_are_not_duplicated(self):
        self.write_memory(self.memory(self.main), {"MEMORY.md": "- [A](a.md) — x\n", "a.md": "same"})
        self.write_memory(self.memory(self.account), {"MEMORY.md": "- [A](a.md) — x\n", "a.md": "same"})
        self.run_share()
        shared = self.shared / SLUG
        self.assertEqual(sorted(p.name for p in shared.iterdir()), ["MEMORY.md", "a.md"])
        self.assertEqual((shared / "MEMORY.md").read_text().count("(a.md)"), 1)

    def test_clashing_files_keep_both_versions(self):
        self.write_memory(self.memory(self.main), {"MEMORY.md": "- [A](a.md) — main\n", "a.md": "main version"})
        self.write_memory(self.memory(self.account), {"MEMORY.md": "- [A](a.md) — account\n", "a.md": "account version"})
        self.run_share()
        shared = self.shared / SLUG
        self.assertEqual((shared / "a.md").read_text(), "main version")
        self.assertEqual((shared / "a-claude-1.md").read_text(), "account version")
        self.assertIn("(a-claude-1.md)", (shared / "MEMORY.md").read_text())

    def test_empty_memory_folder_waits_until_there_is_something_to_share(self):
        self.memory(self.account).mkdir(parents=True)
        self.run_share()
        self.assertFalse(self.memory(self.account).is_symlink())
        self.assertFalse((self.shared / SLUG).exists())
        self.write_memory(self.memory(self.main), {"MEMORY.md": "- [A](a.md) — x\n", "a.md": "a"})
        self.run_share()
        self.assertTrue(self.memory(self.account).is_symlink())

    def test_project_without_memory_is_linked_only_when_shared_has_some(self):
        self.write_memory(self.shared / SLUG, {"MEMORY.md": "- [A](a.md) — x\n", "a.md": "a"})
        (self.account / "projects" / SLUG).mkdir(parents=True)
        (self.account / "projects" / "-tmp-scratch").mkdir(parents=True)
        self.run_share()
        self.assertTrue(self.memory(self.account).is_symlink())
        self.assertFalse(os.path.lexists(self.memory(self.account, "-tmp-scratch")))
        self.assertFalse((self.shared / "-tmp-scratch").exists())

    def test_current_session_project_is_always_linked(self):
        for login in (self.account, self.main):
            transcript = login / "projects" / "-new-project" / "abc.jsonl"
            transcript.parent.mkdir(parents=True)
            self.run_share(current_transcript=transcript)
            self.assertEqual(os.readlink(self.memory(login, "-new-project")), str(self.shared / "-new-project"))

    def test_current_session_project_folder_can_be_missing(self):
        # SessionStart fires before Claude Code creates the project folder.
        transcript = self.account / "projects" / "-brand-new" / "abc.jsonl"
        (self.account / "projects").mkdir(parents=True)
        self.run_share(current_transcript=transcript)
        self.assertEqual(os.readlink(self.memory(self.account, "-brand-new")), str(self.shared / "-brand-new"))

    def test_transcripts_elsewhere_are_ignored(self):
        transcript = Path(self.tmp.name) / "other" / "projects" / "-x" / "abc.jsonl"
        transcript.parent.mkdir(parents=True)
        self.run_share(current_transcript=transcript)
        self.assertFalse(os.path.lexists(transcript.parent / "memory"))

    def test_links_pointing_somewhere_else_are_left_alone(self):
        elsewhere = Path(self.tmp.name) / "elsewhere"
        elsewhere.mkdir()
        (self.account / "projects" / SLUG).mkdir(parents=True)
        os.symlink(elsewhere, self.memory(self.account))
        report = self.run_share()
        self.assertEqual(os.readlink(self.memory(self.account)), str(elsewhere))
        self.assertTrue(report.skipped)

    def test_adds_memory_allow_rules_and_the_hook_once(self):
        self.run_share(hook_command="token-stats share-config --hook")
        self.run_share(hook_command="token-stats share-config --hook")
        settings = self.settings()
        self.assertEqual(settings["model"], "opus")
        allow = settings["permissions"]["allow"]
        shared_rule = f"Edit(/{self.shared}/**)"
        self.assertIn(shared_rule, allow)
        self.assertIn(f"Read(/{self.accounts}/*/projects/*/memory/**)", allow)
        self.assertEqual(allow.count(shared_rule), 1)
        hooks = settings["hooks"]["SessionStart"]
        self.assertEqual(len(hooks), 1)
        self.assertEqual(hooks[0]["hooks"][0]["command"], "token-stats share-config --hook")

    def test_rules_under_home_use_the_tilde_form(self):
        rules = share_config.memory_rules(Path.home() / ".claude", Path.home() / "Accounts", Path.home() / ".agents" / "memory")
        self.assertIn("Edit(~/.agents/memory/**)", rules)
        self.assertIn("Read(~/.claude/projects/*/memory/**)", rules)

    def test_dry_run_changes_nothing(self):
        self.write_memory(self.memory(self.account), {"MEMORY.md": "- [B](b.md) — x\n", "b.md": "b"})
        before = (self.main / "settings.json").read_text()
        report = self.run_share(dry_run=True, hook_command="hook")
        self.assertFalse(self.memory(self.account).is_symlink())
        self.assertFalse((self.account / "CLAUDE.md").exists())
        self.assertEqual((self.main / "settings.json").read_text(), before)
        self.assertTrue(report.changes)

    def test_second_run_has_nothing_to_do(self):
        self.write_memory(self.memory(self.account), {"MEMORY.md": "- [B](b.md) — x\n", "b.md": "b"})
        self.run_share(hook_command="x share-config --hook")
        self.assertEqual(self.run_share(hook_command="x share-config --hook").changes, [])

    def test_hook_mode_reads_the_transcript_path_from_stdin_and_prints_nothing(self):
        transcript = self.account / "projects" / "-hooked" / "abc.jsonl"
        transcript.parent.mkdir(parents=True)
        script = Path(__file__).resolve().parent.parent / "share_config.py"
        result = subprocess.run(
            [sys.executable, str(script), "--hook", "--main", str(self.main), "--accounts", str(self.accounts),
             "--shared-memory", str(self.shared)],
            input=json.dumps({"transcript_path": str(transcript), "hook_event_name": "SessionStart"}),
            capture_output=True,
            text=True,
            check=True,
        )
        self.assertEqual(result.stdout, "")
        self.assertTrue(self.memory(self.account, "-hooked").is_symlink())
        # The hook never adds itself; only a manual run does.
        self.assertNotIn("hooks", self.settings())


if __name__ == "__main__":
    unittest.main()
