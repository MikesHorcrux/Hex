#!/usr/bin/env bash
set -euo pipefail

readonly MODE="${1:-run}"
readonly APP_NAME="Hex"
readonly BUNDLE_ID="com.lunarmothstudios.Hex"
readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_PATH="$ROOT_DIR/Hex.xcodeproj"
readonly DERIVED_DATA_PATH="$ROOT_DIR/.build/DerivedData"
readonly GATEWAY_BUILD_PATH="$ROOT_DIR/.build/HexGateway"
readonly BUILD_APP="$DERIVED_DATA_PATH/Build/Products/Debug/$APP_NAME.app"
readonly DIST_DIR="$ROOT_DIR/dist"
readonly APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
readonly APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
readonly GATEWAY_BUNDLE_BINARY="$APP_BUNDLE/Contents/Resources/HexGateway"
readonly BUNDLED_LAUNCH_AGENT="$APP_BUNDLE/Contents/Library/LaunchAgents/com.lunarmothstudios.hex.gateway.plist"
readonly LAUNCH_AGENT_SOURCE="$ROOT_DIR/Resources/LaunchAgent/com.lunarmothstudios.hex.gateway.plist"
readonly XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
gateway_bin_path=""
verified_app_pid=""

usage() {
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
}

is_staged_app_pid() {
    local candidate_pid="$1"
    local candidate_command

    case "$candidate_pid" in
        "" | *[!0-9]*)
            return 1
            ;;
    esac

    candidate_command="$(/bin/ps -p "$candidate_pid" -o command= 2>/dev/null || true)"
    case "$candidate_command" in
        "$APP_BINARY" | "$APP_BINARY "*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

matching_staged_app_pids() {
    local candidate_pid

    while IFS= read -r candidate_pid; do
        if is_staged_app_pid "$candidate_pid"; then
            echo "$candidate_pid"
        fi
    done < <(/usr/bin/pgrep -x "$APP_NAME" 2>/dev/null || true)
}

terminate_staged_app_pid() {
    local candidate_pid="$1"
    local attempt=0

    if ! is_staged_app_pid "$candidate_pid"; then
        return 0
    fi

    /bin/kill -TERM "$candidate_pid" 2>/dev/null || true
    while ((attempt < 20)); do
        if ! is_staged_app_pid "$candidate_pid"; then
            return 0
        fi
        /bin/sleep 0.1
        attempt=$((attempt + 1))
    done

    if is_staged_app_pid "$candidate_pid"; then
        /bin/kill -KILL "$candidate_pid" 2>/dev/null || true
    fi

    attempt=0
    while ((attempt < 10)); do
        if ! is_staged_app_pid "$candidate_pid"; then
            return 0
        fi
        /bin/sleep 0.1
        attempt=$((attempt + 1))
    done

    return 1
}

cleanup_verified_app() {
    if [[ -n "$verified_app_pid" ]]; then
        terminate_staged_app_pid "$verified_app_pid" || true
    fi
}

stop_running_staged_apps() {
    local candidate_pid

    while IFS= read -r candidate_pid; do
        if ! terminate_staged_app_pid "$candidate_pid"; then
            echo "could not stop staged $APP_NAME process $candidate_pid" >&2
            return 1
        fi
    done < <(matching_staged_app_pids)
}

wait_for_verified_app() {
    local verification_token="$1"
    local attempt=0
    local candidate_pid
    local candidate_command

    while ((attempt < 20)); do
        while IFS= read -r candidate_pid; do
            candidate_command="$(/bin/ps -p "$candidate_pid" -o command= 2>/dev/null || true)"
            if [[ "$candidate_command" == *"$verification_token"* ]]; then
                echo "$candidate_pid"
                return 0
            fi
        done < <(matching_staged_app_pids)
        /bin/sleep 0.25
        attempt=$((attempt + 1))
    done

    return 1
}

case "$MODE" in
    run | --debug | debug | --logs | logs | --telemetry | telemetry | --verify | verify)
        ;;
    *)
        usage
        exit 2
        ;;
esac

stop_running_staged_apps

DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" /usr/bin/xcodebuild \
    build \
    -project "$PROJECT_PATH" \
    -scheme "$APP_NAME" \
    -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -parallelizeTargets NO \
    -jobs 1 \
    CODE_SIGNING_ALLOWED=NO

if [[ ! -d "$BUILD_APP" ]]; then
    echo "built app was not found at $BUILD_APP" >&2
    exit 1
fi

gateway_bin_path="$({
    DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" /usr/bin/xcrun swift build \
        --package-path "$ROOT_DIR/Packages/HexKit" \
        --scratch-path "$GATEWAY_BUILD_PATH" \
        --product HexGateway \
        --configuration debug \
        --show-bin-path
})"

DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" /usr/bin/xcrun swift build \
    --package-path "$ROOT_DIR/Packages/HexKit" \
    --scratch-path "$GATEWAY_BUILD_PATH" \
    --product HexGateway \
    --configuration debug \
    -j 1

if [[ ! -x "$gateway_bin_path/HexGateway" ]]; then
    echo "built HexGateway executable was not found at $gateway_bin_path/HexGateway" >&2
    exit 1
fi

mkdir -p "$DIST_DIR"
rm -rf "$APP_BUNDLE"
/usr/bin/ditto "$BUILD_APP" "$APP_BUNDLE"

if [[ ! -f "$LAUNCH_AGENT_SOURCE" ]]; then
    echo "bundle-ready LaunchAgent plist is missing at $LAUNCH_AGENT_SOURCE" >&2
    echo "This developer packaging path does not synthesize or install a LaunchAgent." >&2
    exit 1
fi

mkdir -p "$(dirname "$GATEWAY_BUNDLE_BINARY")" "$(dirname "$BUNDLED_LAUNCH_AGENT")"
/usr/bin/install -m 0755 "$gateway_bin_path/HexGateway" "$GATEWAY_BUNDLE_BINARY"
/usr/bin/install -m 0644 "$LAUNCH_AGENT_SOURCE" "$BUNDLED_LAUNCH_AGENT"

verify_gateway_bundle() {
    if [[ ! -x "$GATEWAY_BUNDLE_BINARY" ]]; then
        echo "packaged HexGateway helper is not executable at $GATEWAY_BUNDLE_BINARY" >&2
        return 1
    fi
    if [[ ! -f "$BUNDLED_LAUNCH_AGENT" ]]; then
        echo "packaged LaunchAgent plist is missing at $BUNDLED_LAUNCH_AGENT" >&2
        return 1
    fi
    /usr/bin/plutil -lint "$BUNDLED_LAUNCH_AGENT" >/dev/null
    local bundle_program
    bundle_program="$(/usr/bin/plutil -extract BundleProgram raw -o - "$BUNDLED_LAUNCH_AGENT")"
    if [[ "$bundle_program" != "Contents/Resources/HexGateway" ]]; then
        echo "LaunchAgent BundleProgram must be Contents/Resources/HexGateway" >&2
        return 1
    fi
}

verify_gateway_bundle

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
        verify_gateway_bundle
        verification_token="hex-verification-$$-$RANDOM"
        /usr/bin/open -n "$APP_BUNDLE" --args "$verification_token"

        if ! verified_app_pid="$(wait_for_verified_app "$verification_token")"; then
            echo "staged $APP_NAME did not launch within five seconds" >&2
            exit 1
        fi
        trap cleanup_verified_app EXIT

        /bin/sleep 0.25
        if ! is_staged_app_pid "$verified_app_pid"; then
            echo "staged $APP_NAME process exited during launch verification" >&2
            exit 1
        fi
        if ! terminate_staged_app_pid "$verified_app_pid"; then
            echo "could not stop verified $APP_NAME process $verified_app_pid" >&2
            exit 1
        fi
        verified_app_pid=""
        trap - EXIT

        echo "verified staged Debug app launch and packaged gateway layout at $APP_BUNDLE"
        ;;
esac
