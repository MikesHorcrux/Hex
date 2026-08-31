#!/usr/bin/env bash
set -euo pipefail

readonly MODE="${1:-run}"
readonly APP_NAME="Hex"
readonly BUNDLE_ID="com.lunarmothstudios.Hex"
readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_PATH="$ROOT_DIR/Hex.xcodeproj"
readonly DERIVED_DATA_PATH="$ROOT_DIR/.build/DerivedData"
readonly BUILD_APP="$DERIVED_DATA_PATH/Build/Products/Debug/$APP_NAME.app"
readonly DIST_DIR="$ROOT_DIR/dist"
readonly APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
readonly APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
readonly XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

usage() {
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
}

case "$MODE" in
    run | --debug | debug | --logs | logs | --telemetry | telemetry | --verify | verify)
        ;;
    *)
        usage
        exit 2
        ;;
esac

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" /usr/bin/xcodebuild \
    build \
    -project "$PROJECT_PATH" \
    -scheme "$APP_NAME" \
    -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    CODE_SIGNING_ALLOWED=NO

if [[ ! -d "$BUILD_APP" ]]; then
    echo "built app was not found at $BUILD_APP" >&2
    exit 1
fi

mkdir -p "$DIST_DIR"
rm -rf "$APP_BUNDLE"
/usr/bin/ditto "$BUILD_APP" "$APP_BUNDLE"

open_app() {
    /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
    run)
        open_app
        ;;
    --debug | debug)
        DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" /usr/bin/xcrun lldb -- "$APP_BINARY"
        ;;
    --logs | logs)
        open_app
        exec /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
        ;;
    --telemetry | telemetry)
        open_app
        exec /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
        ;;
    --verify | verify)
        test -x "$APP_BINARY"
        /usr/bin/plutil -lint "$APP_BUNDLE/Contents/Info.plist" >/dev/null
        echo "verified unsigned Debug app at $APP_BUNDLE"
        ;;
esac
