#!/usr/bin/env bash
# Moves the server's protocol pin to another Shorebird CLI release.
#
#   tool/sync_protocol.sh 1.6.141        # review the drift, then apply
#   tool/sync_protocol.sh 1.6.141 --check  # only report the drift (CI)
#
# One CLI version fixes the whole contract: the CLI commit (openapi.yaml,
# client routes, protocol package), its Flutter fork revision
# (bin/internal/flutter.version), and the updater commit that revision's
# DEPS pins. Every derived file in protocol/ is regenerated from those.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?usage: sync_protocol.sh <cli-version> [--check]}"
MODE="${2:-apply}"
source "$ROOT/protocol/shorebird.lock"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CLI_SHA="$(git ls-remote https://github.com/shorebirdtech/shorebird.git "refs/tags/v$VERSION^{}" | cut -f1)"
[ -n "$CLI_SHA" ] || CLI_SHA="$(git ls-remote https://github.com/shorebirdtech/shorebird.git "refs/tags/v$VERSION" | cut -f1)"
[ -n "$CLI_SHA" ] || { echo "No tag v$VERSION"; exit 2; }

raw() { curl -fsSL "https://raw.githubusercontent.com/$1/$2/$3"; }
raw shorebirdtech/shorebird "$CLI_SHA" packages/shorebird_code_push_protocol/openapi.yaml > "$WORK/openapi.yaml"
raw shorebirdtech/shorebird "$CLI_SHA" packages/shorebird_code_push_client/lib/src/code_push_client.dart > "$WORK/code_push_client.dart"
FLUTTER_REV="$(raw shorebirdtech/shorebird "$CLI_SHA" bin/internal/flutter.version | tr -d '[:space:]')"
UPDATER_SHA_NEW="$(raw shorebirdtech/flutter "$FLUTTER_REV" DEPS | sed -n 's/.*"updater_rev": "\([0-9a-f]*\)".*/\1/p')"
[ -n "$UPDATER_SHA_NEW" ] || { echo "Could not read updater_rev from flutter@$FLUTTER_REV DEPS"; exit 2; }
mkdir -p "$WORK/updater"
for f in network.rs events.rs yaml.rs cache/signing.rs; do
  raw shorebirdtech/updater "$UPDATER_SHA_NEW" "library/src/$f" > "$WORK/updater/$(basename "$f")"
done
python3 -I "$ROOT/tool/extract_client_routes.py" "$WORK/code_push_client.dart" > "$WORK/client_routes.txt"

echo "== Shorebird $SHOREBIRD_CLI_VERSION -> $VERSION"
echo "   cli     $SHOREBIRD_CLI_SHA -> $CLI_SHA"
echo "   flutter ${FLUTTER_REVISION:-?} -> $FLUTTER_REV"
echo "   updater $UPDATER_SHA -> $UPDATER_SHA_NEW"
DRIFT=0
echo; echo "== openapi.yaml (CLI <-> server)"
python3 -I "$ROOT/tool/spec_diff.py" "$ROOT/protocol/openapi.yaml" "$WORK/openapi.yaml" || DRIFT=1
echo; echo "== client routes outside the spec"
diff "$ROOT/protocol/client_routes.txt" "$WORK/client_routes.txt" || DRIFT=1
echo; echo "== updater (device <-> server)"
diff -ru "$ROOT/protocol/updater" "$WORK/updater" || DRIFT=1

if [ "$MODE" = "--check" ]; then
  [ $DRIFT = 0 ] && echo "No protocol drift." || echo "Protocol drift found; review above, then run without --check."
  exit $DRIFT
fi

cp "$WORK/openapi.yaml" "$ROOT/protocol/openapi.yaml"
cp "$WORK/client_routes.txt" "$ROOT/protocol/client_routes.txt"
cp "$WORK/updater/"* "$ROOT/protocol/updater/"
cat > "$ROOT/protocol/shorebird.lock" <<LOCK
# The exact Shorebird sources this server's protocol is pinned to.
# Change only via tool/sync_protocol.sh, which updates every derived file.
SHOREBIRD_CLI_VERSION=$VERSION
SHOREBIRD_CLI_SHA=$CLI_SHA
FLUTTER_REVISION=$FLUTTER_REV
UPDATER_SHA=$UPDATER_SHA_NEW
LOCK
sed -i "s/^      ref: [0-9a-f]\{40\}$/      ref: $CLI_SHA/" "$ROOT/server/pubspec.yaml"
(cd "$ROOT/server" && dart pub get && dart analyze && dart test)
# The console's types come from the same spec.
(cd "$ROOT/dashboard" && bun run gen:api && bun run typecheck)
echo
echo "Pinned to $VERSION. Next: review docs/PROTOCOL.md against the updater diff,"
echo "classify new operations in protocol/operations.yaml, run e2e/run.sh."
