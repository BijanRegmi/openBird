#!/usr/bin/env bash
# Installs the Shorebird CLI version this server is pinned to (protocol/shorebird.lock)
# into .tools/shorebird, leaving any global Shorebird install untouched.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/protocol/shorebird.lock"
DEST="$ROOT/.tools/shorebird"
if [ ! -d "$DEST/.git" ]; then
  git clone --quiet --filter=blob:none https://github.com/shorebirdtech/shorebird.git "$DEST"
fi
git -C "$DEST" fetch --quiet --tags origin
git -C "$DEST" -c advice.detachedHead=false checkout --quiet "$SHOREBIRD_CLI_SHA"
# First run bootstraps the Shorebird Flutter fork and builds the CLI snapshot.
"$DEST/bin/shorebird" --version
