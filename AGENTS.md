# Agent guidance for token-stats

## Repo purpose

A native SwiftUI dashboard for local Codex and Claude Code token usage, with
optional OpenRouter activity and CSV imports. This repository is macOS only,
requires macOS 14 or later, and is a self-contained Swift package.

## Working rules

- Use test-first development for non-trivial changes. Write or update the
  automated test first, then implement until it passes. Extract a test seam
  first if needed.
- When behaviour changes, update affected expectations and rerun the relevant
  tests. This includes UI copy, layout, persistence, and startup behaviour.
- Test before committing. Run `swift test`, then verify the actual app or script
  affected by the change and check its exit code.
- Keep source in this clone. `install.sh` stages the app and links the launcher
  into `~/.local/bin`; rerun it after moving the clone.
- Do not commit build output, app bundles, caches, logs, or API keys.
- Keep UI copy plain and avoid eyebrow or kicker labels.

## Architecture and data

- `Package.swift` defines the `TokenStatsApp` executable and
  `TokenStatsAppTests`. There are no external package dependencies.
- `Sources/TokenStatsApp/UsageParsers.swift` parses local session logs and
  OpenRouter data. Preserve cumulative Codex deltas and Claude message-ID
  deduplication when changing parsers.
- `UsageStore.swift` loads local histories and persists the CSV bookmark.
  `UsageStore.shared` lives for the whole app so reopening the window doesn't
  reload. `UsageFileIndex.swift` caches each log file's records by size and
  modification time (`claude-index-v1.json`, `codex-index-v2.json` under
  `~/Library/Application Support/Token Stats`) and holds `JSONLReader`, which
  streams files. Never read a whole session log into memory: they run to
  gigabytes and that's what made the app use 5 GB. Ripgrep is optional; keep
  the Swift fallback working. `token-stats usage` prints totals for checking.
- `PricingCatalog.swift` contains dated API price estimates. Unknown model
  tokens still count even when no price is available.
- `OpenRouterActivity.swift` builds read-only activity requests and stores the
  management key in Keychain. Keep keys out of URLs, logs, and preferences.
  Exact OpenRouter billed usage wins over estimates; don't add BYOK estimates.
- Keep the existing bundle ID, Keychain service, preferences keys, and cache
  location compatible with existing installations.
- Plan limits: `PlanLimits.swift` holds the models and pure parsers (tested),
  `LimitsClients.swift` talks to `codex app-server` (JSON-RPC over stdio) and
  Anthropic's OAuth usage endpoint using Claude Code's Keychain login (read
  via `/usr/bin/security`, which Claude Code writes with, so there's no
  prompt; never read it with SecItem APIs), and
  `LimitsStore.swift` discovers accounts, refreshes every 5 minutes and backs
  both the menu bar (`LimitsViews.swift`) and the dashboard section. Never renew or
  rewrite the main logins (`~/.claude`, `~/.codex`, Grok, Muse); their own CLIs
  do that, and two programs renewing one login sign each other out. The one
  exception is Claude logins Token Stats made in its Accounts folder, which
  nothing else uses: `ClaudeLimitsClient` renews those near expiry with their
  refresh token (`ClaudeLoginRenewal`), under a `flock` in the login's folder,
  and saves them back with `security -i` the way Claude Code does. Never log
  tokens. `LimitAccountMerger` shows one
  card per email and removes duplicate logins Token Stats made itself. `token-stats limits` prints
  the same data for checking without the UI.
- `CLIUpdater.swift` updates the agent CLIs once a day (checked hourly) and
  `token-stats update-clis` runs it by hand. Keep the updates sequential and
  never start an agent session to update one (Muse uses `MUSE_LAUNCHER_INSTALL=1`).
- The app is a `MenuBarExtra` plus one `Window`. Closing the window drops it to
  an accessory app; it only quits from the menu's Quit button.
- `DashboardSnapshot.swift` and `UsageAggregator.swift` build daily summaries;
  `DashboardView.swift` renders the app and PNG export.

## Development and verification

```bash
swift test
bash restart.sh
```

`restart.sh` kills the running app, stages a debug bundle, and opens it.
`setup_mac.sh` stages a release bundle. `install.sh [target_bin_dir]` calls setup
and installs the launcher symlink (default `~/.local/bin`). `token-stats` resolves
that symlink so its subcommands find scripts in this clone.

For bundle verification without replacing the installed app:

```bash
TOKEN_STATS_APP_DIR="/tmp/Token Stats.app" bash build-app.sh
codesign --verify --deep --strict "/tmp/Token Stats.app"
```

CI runs `swift test`, shell syntax checks, and a release executable build on macOS.
Tests use fixtures and request construction only, so no live API access or
hardware permissions are required. Check real dashboard interaction, export,
and Keychain access manually when changing those paths.
