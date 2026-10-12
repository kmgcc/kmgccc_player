#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
case "$MODE" in
  run|--debug|--logs|--telemetry|--verify) ;;
  --help|-h)
    printf '%s\n' 'Usage: ./script/build_and_run.sh [--debug|--logs|--telemetry|--verify]'
    exit 0
    ;;
  *) printf 'Unknown mode: %s\n' "$MODE" >&2; exit 2 ;;
esac

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="PopupLab"
BUNDLE_ID="com.kmgccc.PopupLab"
APP_BUNDLE="$LAB_ROOT/dist/$APP_NAME.app"

# This entrypoint is exclusively for the lab, with its own binary and build directory.
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
swift build --package-path "$LAB_ROOT" --scratch-path "$LAB_ROOT/.build" --product "$APP_NAME" -c debug
BUILD_DIRECTORY="$(swift build --package-path "$LAB_ROOT" --scratch-path "$LAB_ROOT/.build" -c debug --show-bin-path)"

mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp "$BUILD_DIRECTORY/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Popup Lab</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

case "$MODE" in
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ;;
  --logs|--telemetry)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate 'process == "PopupLab"'
    ;;
  --verify)
    /usr/bin/open -n "$APP_BUNDLE"
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    ;;
esac
