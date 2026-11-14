#!/usr/bin/env bash
# End-to-end check of the whole system with real parts: the pinned Shorebird
# CLI (.tools/shorebird), the Shorebird engine and updater in a real Android
# build, this server, and a running emulator or device.
#
#   docker compose up -d postgres && tool/dev.sh &      # server on :8080
#   [DEVICE_PIN=0000] e2e/run.sh [adb-serial]
#
# Steps: init a fresh app -> release -> install -> patch -> device downloads,
# verifies the managed signature and boots the patch -> rollback -> device
# reverts to the release. Fails on the first step that doesn't happen.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/e2e/sample_app"
SB="$ROOT/.tools/shorebird/bin/shorebird"
SERIAL="${1:-$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')}"
SERVER="${SERVER:-http://localhost:8080}"
PORT="${SERVER##*:}"
PACKAGE=dev.openbird.sample_app
[ -n "$SERIAL" ] || { echo "No adb device"; exit 1; }
[ -x "$SB" ] || "$ROOT/tool/install_cli.sh"
set -a; source "$ROOT/.env"; set +a
: "${SHOREBIRD_TOKEN:?add SHOREBIRD_TOKEN (tool/admin.sh create-key) to .env}"
A=(adb -s "$SERIAL")

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
api() { curl -fsS -H "authorization: Bearer $SHOREBIRD_TOKEN" "$SERVER/api/v1/$1"; }
screen_has() {
  for _ in $(seq 30); do
    "${A[@]}" shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1 || true
    "${A[@]}" shell cat /sdcard/ui.xml 2>/dev/null | grep -q "$1" && return 0
    sleep 1
  done
  echo "Screen never showed '$1'"; return 1
}
launch() {
  # Builds take minutes; the device may have locked meanwhile.
  "${A[@]}" shell input keyevent KEYCODE_WAKEUP
  "${A[@]}" shell wm dismiss-keyguard >/dev/null 2>&1 || true
  # A PIN-locked device needs the PIN (DEVICE_PIN) before apps can start.
  if [ -n "${DEVICE_PIN:-}" ] && "${A[@]}" shell dumpsys window | grep -q 'isKeyguardShowing=true'; then
    "${A[@]}" shell input text "$DEVICE_PIN"
    "${A[@]}" shell input keyevent KEYCODE_ENTER
    sleep 2
  fi
  "${A[@]}" shell am force-stop "$PACKAGE"
  "${A[@]}" logcat -c
  "${A[@]}" shell am start -n "$PACKAGE/.MainActivity" >/dev/null
}
updater_status() {
  for _ in $(seq 60); do
    local line
    line="$("${A[@]}" logcat -d | grep -m1 'Update thread finished with status' || true)"
    if [ -n "$line" ]; then echo "${line##*status: }"; return 0; fi
    sleep 1
  done
  echo "updater never finished"; return 1
}
set_marker() { sed -i "s/^const marker = .*/const marker = '$1';/" "$APP/lib/main.dart"; }
trap 'set_marker "OPENBIRD BASE"' EXIT

case "$("${A[@]}" shell getprop ro.product.cpu.abi | tr -d '\r')" in
  x86_64) TARGET=android-x64 ;;
  arm64-v8a) TARGET=android-arm64 ;;
  armeabi-v7a) TARGET=android-arm ;;
  *) echo "Unsupported ABI"; exit 1 ;;
esac
VERSION="1.0.$(date +%s)+1"

step "Server and device"
curl -fsS "$SERVER/healthz" >/dev/null
"${A[@]}" shell svc power stayon true
"${A[@]}" shell input keyevent KEYCODE_WAKEUP
"${A[@]}" reverse "tcp:$PORT" "tcp:$PORT" >/dev/null

step "shorebird init (fresh app)"
cd "$APP"
ORG_ID="$(api organizations | python3 -c 'import json,sys; print(json.load(sys.stdin)["organizations"][0]["organization"]["id"])')"
rm -f shorebird.yaml
SHOREBIRD_HOSTED_URL="$SERVER" "$SB" init --force --org-id "$ORG_ID" --display-name "e2e $VERSION" >/dev/null
printf '\nbase_url: %s\n' "$SERVER" >> shorebird.yaml
sed -i "s/^version: .*/version: $VERSION/" pubspec.yaml
APP_ID="$(sed -n 's/^app_id: //p' shorebird.yaml)"
echo "app $APP_ID, release $VERSION, $TARGET"

step "shorebird release android"
set_marker "OPENBIRD BASE"
"$SB" release android --artifact apk --target-platform "$TARGET" --no-confirm
"${A[@]}" install -r build/app/outputs/flutter-apk/app-release.apk >/dev/null
launch
screen_has "OPENBIRD BASE"
[ "$(updater_status)" = "No update" ]

step "shorebird patch android"
set_marker "OPENBIRD PATCHED"
"$SB" patch android --release-version "$VERSION" --no-confirm
launch
status="$(updater_status)"; echo "updater: $status"
[ "$status" = "Update installed" ]
"${A[@]}" logcat -d | grep -q "Patch signature is valid"
launch
screen_has "OPENBIRD PATCHED"

step "shorebird patches rollback"
"$SB" patches rollback --release-version "$VERSION" --patch-number 1 >/dev/null
launch
updater_status >/dev/null
"${A[@]}" logcat -d | grep -q "rolled_back_patch_numbers: Some(\[1\])"
launch
screen_has "OPENBIRD BASE"

step "Device events"
api "apps/$APP_ID" >/dev/null
echo "OK: release, patch (signed), rollback all verified on $SERIAL"
