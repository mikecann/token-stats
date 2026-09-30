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
- `UsageStore.swift` loads local histories, persists the CSV bookmark, and
  caches the Codex index under `~/Library/Application Support/Token Stats`.
  Ripgrep is optional; keep the Swift fallback working.
- `PricingCatalog.swift` contains dated API price estimates. Unknown model
  tokens still count even when no price is available.
- `OpenRouterActivity.swift` builds read-only activity requests and stores the
  management key in Keychain. Keep keys out of URLs, logs, and preferences.
  Exact OpenRouter billed usage wins over estimates; don't add BYOK estimates.
- Keep the existing bundle ID, Keychain service, preferences keys, and cache
  location compatible with existing installations.
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
