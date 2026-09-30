#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${TOKEN_STATS_APP_DIR:-$HOME/Applications/Token Stats.app}"

TOKEN_STATS_BUILD_CONFIGURATION=release bash "$SCRIPT_DIR/build-app.sh"
echo ""
echo "Token Stats is installed at $APP_DIR"
echo "Launch it with: token-stats"
