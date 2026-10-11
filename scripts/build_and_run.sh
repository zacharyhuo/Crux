#!/usr/bin/env bash
set -euo pipefail

# This entrypoint intentionally has no production mode.
readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly APP_NAME="Crux Beta"
readonly BUNDLE_ID="com.zacharyhuo.Crux.Beta"
readonly DERIVED_DATA="$ROOT_DIR/build/Beta"
readonly APP_BUNDLE="$DERIVED_DATA/Build/Products/BetaDebug/$APP_NAME.app"
readonly MODE="${1:-run}"

case "$MODE" in
  --help)
    echo 'Usage: scripts/build_and_run.sh [run|--build-only|--verify|--logs|--telemetry|--debug]'
    echo 'Only builds/launches Crux Beta. Never touches production Crux.'
    exit 0 ;;
  run|--build-only|--verify|--logs|--telemetry|--debug) ;;
  *) echo "Unknown mode: $MODE" >&2; exit 2 ;;
esac

cd "$ROOT_DIR"
if [[ "$MODE" != --build-only ]]; then
  # An exact, distinct executable name; never pkill Crux or match a prefix.
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi
xcodebuild -project Crux.xcodeproj -scheme "$APP_NAME" \
  -configuration BetaDebug -derivedDataPath "$DERIVED_DATA" \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY=- \
  CRUX_CODE_SIGN_ENTITLEMENTS=Crux/Crux-AdHoc.entitlements build

actual_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_BUNDLE/Contents/Info.plist")"
[[ "$actual_id" == "$BUNDLE_ID" ]] || { echo 'Refusing to launch a non-Beta bundle' >&2; exit 1; }
[[ "$MODE" == --build-only ]] && exit 0
if [[ "$MODE" == --debug ]]; then
  exec lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
fi
/usr/bin/open -n "$APP_BUNDLE"
case "$MODE" in
  --verify) sleep 2; pgrep -x "$APP_NAME" >/dev/null ;;
  --logs) exec /usr/bin/log stream --info --style compact --predicate 'process == "Crux Beta"' ;;
  --telemetry) exec /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.zacharyhuo.Crux.Beta"' ;;
esac
