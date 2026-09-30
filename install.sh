#!/usr/bin/env bash
# Re-run after moving the clone so the launcher symlink points at its new home.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${1:-$HOME/.local/bin}"

case "${1:-}" in
  -h|--help)
    echo "Usage: install.sh [target_bin_dir]"
    echo "Builds Token Stats.app and links token-stats (default: ~/.local/bin)."
    exit 0
    ;;
  -*)
    echo "Unknown option: $1 (try --help)" >&2
    exit 2
    ;;
esac
if [[ $# -gt 1 ]]; then
  echo "Usage: install.sh [target_bin_dir]" >&2
  exit 2
fi

for dependency in swift python3; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    echo "ERROR: $dependency is not on PATH. Install Xcode Command Line Tools first." >&2
    exit 1
  fi
done

DESTINATION="$TARGET_DIR/token-stats"
# An existing symlink can be updated, but do not replace someone's own command.
if [[ -e "$DESTINATION" && ! -L "$DESTINATION" ]]; then
  echo "ERROR: $DESTINATION already exists and is not a symlink." >&2
  exit 1
fi
if [[ -d "$DESTINATION" ]]; then
  echo "ERROR: $DESTINATION points to a directory." >&2
  exit 1
fi

bash "$SCRIPT_DIR/setup_mac.sh"
mkdir -p "$TARGET_DIR"
chmod +x "$SCRIPT_DIR/token-stats"
ln -sfn "$SCRIPT_DIR/token-stats" "$DESTINATION"
echo "Linked $DESTINATION -> $SCRIPT_DIR/token-stats"

case ":$PATH:" in
  *":$TARGET_DIR:"*) ;;
  *)
    echo "Add this directory to PATH in your shell profile: $TARGET_DIR"
    ;;
esac
echo "Launch it with: $DESTINATION"
