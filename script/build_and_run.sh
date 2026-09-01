#!/usr/bin/env bash
set -euo pipefail

readonly MODE="${1:-run}"
readonly APP_NAME="Hex"
readonly BUNDLE_ID="com.lunarmothstudios.Hex"
readonly EXPECTED_TEAM_ID="5V5PZUN2HG"
readonly HELPER_BUNDLE_ID="com.lunarmothstudios.hex.gateway"
readonly RESIDENT_KEYCHAIN_GROUP="5V5PZUN2HG.com.lunarmothstudios.Hex.resident"
readonly APP_CODE_SIGNING_REQUIREMENT='anchor apple generic and identifier "com.lunarmothstudios.Hex" and certificate leaf[subject.OU] = "5V5PZUN2HG"'
readonly VERIFY_NO_CONNECT_ARGUMENT="--hex-verify-no-connect"
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
readonly APP_ENTITLEMENTS_SOURCE="$ROOT_DIR/Config/Hex.Debug.entitlements"
readonly XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
gateway_bin_path=""
verified_app_pid=""
signing_material_dir=""
app_entitlements_path=""
app_entitlements_after_path=""
helper_entitlements_path=""
helper_entitlements_after_path=""
signing_identity=""

usage() {
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
}

fail() {
    echo "$*" >&2
    exit 1
}

cleanup_signing_material() {
    if [[ -n "$signing_material_dir" && -d "$signing_material_dir" ]]; then
        /bin/rm -rf "$signing_material_dir"
    fi
}

codesign_details_for() {
    local artifact="$1"
    /usr/bin/codesign -dvvv "$artifact" 2>&1
}

codesign_field() {
    local field="$1"
    local details="$2"
    /usr/bin/printf '%s\n' "$details" | /usr/bin/sed -n "s/^${field}=//p" | /usr/bin/head -n 1
}

apple_development_identity_for() {
    local details="$1"
    /usr/bin/printf '%s\n' "$details" \
        | /usr/bin/sed -n 's/^Authority=Apple Development: /Apple Development: /p' \
        | /usr/bin/head -n 1
}

extract_entitlements() {
    local artifact="$1"
    local destination="$2"
    if ! /usr/bin/codesign -d --entitlements :- "$artifact" > "$destination" 2>/dev/null; then
        fail "could not extract entitlements from $artifact"
    fi
    if ! /usr/bin/plutil -lint "$destination" >/dev/null; then
        fail "extracted entitlements are not a valid plist for $artifact"
    fi
}

validate_single_keychain_group() {
    local entitlements="$1"
    local expected_group="$2"
    local actual_group

    actual_group="$(/usr/bin/plutil -extract keychain-access-groups.0 raw -o - "$entitlements" 2>/dev/null)" \
        || fail "missing keychain-access-groups in $entitlements"
    if [[ "$actual_group" != "$expected_group" ]]; then
        fail "unexpected keychain access group in $entitlements: $actual_group"
    fi
    if /usr/bin/plutil -extract keychain-access-groups.1 raw -o - "$entitlements" >/dev/null 2>&1; then
        fail "more than one keychain access group is present in $entitlements"
    fi
}

write_helper_entitlements() {
    /bin/cat > "$helper_entitlements_path" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>keychain-access-groups</key>
    <array>
        <string>5V5PZUN2HG.com.lunarmothstudios.Hex.resident</string>
    </array>
</dict>
</plist>
EOF
    if ! /usr/bin/plutil -lint "$helper_entitlements_path" >/dev/null; then
        fail "generated helper entitlements are not a valid plist"
    fi
    validate_single_keychain_group "$helper_entitlements_path" "$RESIDENT_KEYCHAIN_GROUP"
}

verify_signed_artifact() {
    local artifact="$1"
    local expected_identifier="$2"
    local expected_team="$3"
    local expected_identity="$4"
    local label="$5"
    local details
    local identifier
    local team_identifier
    local authority
    local test_requirement="${6:-}"

    details="$(codesign_details_for "$artifact")" \
        || fail "could not inspect the $label code signature"
    if ! /usr/bin/codesign --verify --strict "$artifact" >/dev/null; then
        fail "the $label code signature did not pass strict verification"
    fi
    if [[ -n "$test_requirement" ]] \
        && ! /usr/bin/codesign --verify --strict -R="$test_requirement" "$artifact" >/dev/null; then
        fail "the $label code signature did not satisfy the required Apple signing policy"
    fi
    identifier="$(codesign_field Identifier "$details")"
    if [[ "$identifier" != "$expected_identifier" ]]; then
        fail "unexpected $label identifier: $identifier"
    fi
    team_identifier="$(codesign_field TeamIdentifier "$details")"
    if [[ "$team_identifier" != "$expected_team" ]]; then
        fail "unexpected $label team identifier: $team_identifier"
    fi
    authority="$(apple_development_identity_for "$details")"
    if [[ "$authority" != "$expected_identity" ]]; then
        fail "the $label was not signed by the built app's Apple Development identity"
    fi
    if [[ "$details" != *"(runtime)"* ]]; then
        fail "the $label is missing the hardened runtime flag"
    fi
}

cleanup_all() {
    cleanup_verified_app
    cleanup_signing_material
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

trap cleanup_all EXIT

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
    -jobs 1

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

/bin/mkdir -p "$ROOT_DIR/.build"
signing_material_dir="$(/usr/bin/mktemp -d "$ROOT_DIR/.build/hex-signing.XXXXXX")" \
    || fail "could not create temporary signing material directory"
app_entitlements_path="$signing_material_dir/app-before.entitlements"
app_entitlements_after_path="$signing_material_dir/app-after.entitlements"
helper_entitlements_path="$signing_material_dir/helper.entitlements"
helper_entitlements_after_path="$signing_material_dir/helper-after.entitlements"

if ! /usr/bin/plutil -lint "$APP_ENTITLEMENTS_SOURCE" >/dev/null; then
    fail "Debug app entitlements are not a valid plist at $APP_ENTITLEMENTS_SOURCE"
fi
validate_single_keychain_group \
    "$APP_ENTITLEMENTS_SOURCE" \
    '$(AppIdentifierPrefix)com.lunarmothstudios.Hex.resident'

build_signature_details="$(codesign_details_for "$BUILD_APP")" \
    || fail "could not inspect the automatically signed Debug app"
build_identifier="$(codesign_field Identifier "$build_signature_details")"
if [[ "$build_identifier" != "$BUNDLE_ID" ]]; then
    fail "unexpected automatically signed app identifier: $build_identifier"
fi
build_team_identifier="$(codesign_field TeamIdentifier "$build_signature_details")"
if [[ "$build_team_identifier" != "$EXPECTED_TEAM_ID" ]]; then
    fail "unexpected automatically signed app team identifier: $build_team_identifier"
fi
signing_identity="$(apple_development_identity_for "$build_signature_details")"
if [[ -z "$signing_identity" ]]; then
    fail "the Debug app was not signed with an Apple Development identity"
fi
extract_entitlements "$BUILD_APP" "$app_entitlements_path"
validate_single_keychain_group "$app_entitlements_path" "$RESIDENT_KEYCHAIN_GROUP"
write_helper_entitlements

mkdir -p "$DIST_DIR"
rm -rf "$APP_BUNDLE"
/usr/bin/ditto "$BUILD_APP" "$APP_BUNDLE"

if [[ ! -f "$LAUNCH_AGENT_SOURCE" ]]; then
    echo "bundle-ready LaunchAgent plist is missing at $LAUNCH_AGENT_SOURCE" >&2
    echo "This developer packaging path does not synthesize or register a LaunchAgent." >&2
    exit 1
fi

mkdir -p "$(dirname "$GATEWAY_BUNDLE_BINARY")" "$(dirname "$BUNDLED_LAUNCH_AGENT")"
/bin/cp "$gateway_bin_path/HexGateway" "$GATEWAY_BUNDLE_BINARY"
/bin/chmod 0755 "$GATEWAY_BUNDLE_BINARY"
/bin/cp "$LAUNCH_AGENT_SOURCE" "$BUNDLED_LAUNCH_AGENT"
/bin/chmod 0644 "$BUNDLED_LAUNCH_AGENT"

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
    local label
    local bundle_program
    local mach_services
    label="$(/usr/bin/plutil -extract Label raw -o - "$BUNDLED_LAUNCH_AGENT")"
    if [[ "$label" != "$HELPER_BUNDLE_ID" ]]; then
        echo "LaunchAgent Label must be $HELPER_BUNDLE_ID" >&2
        return 1
    fi
    bundle_program="$(/usr/bin/plutil -extract BundleProgram raw -o - "$BUNDLED_LAUNCH_AGENT")"
    if [[ "$bundle_program" != "Contents/Resources/HexGateway" ]]; then
        echo "LaunchAgent BundleProgram must be Contents/Resources/HexGateway" >&2
        return 1
    fi
    mach_services="$(/usr/bin/plutil -extract MachServices json -o - "$BUNDLED_LAUNCH_AGENT")"
    if [[ "$mach_services" != "{\"$HELPER_BUNDLE_ID\":true}" ]]; then
        echo "LaunchAgent MachServices must contain only $HELPER_BUNDLE_ID=true" >&2
        return 1
    fi
}

verify_gateway_bundle

/usr/bin/codesign \
    --force \
    --sign "$signing_identity" \
    --timestamp=none \
    --options runtime \
    --identifier "$HELPER_BUNDLE_ID" \
    --entitlements "$helper_entitlements_path" \
    "$GATEWAY_BUNDLE_BINARY"
verify_signed_artifact \
    "$GATEWAY_BUNDLE_BINARY" \
    "$HELPER_BUNDLE_ID" \
    "$EXPECTED_TEAM_ID" \
    "$signing_identity" \
    "HexGateway helper"
extract_entitlements "$GATEWAY_BUNDLE_BINARY" "$helper_entitlements_after_path"
validate_single_keychain_group "$helper_entitlements_after_path" "$RESIDENT_KEYCHAIN_GROUP"

/usr/bin/codesign \
    --force \
    --sign "$signing_identity" \
    --timestamp=none \
    --options runtime \
    --identifier "$BUNDLE_ID" \
    --entitlements "$app_entitlements_path" \
    "$APP_BUNDLE"
extract_entitlements "$APP_BUNDLE" "$app_entitlements_after_path"
validate_single_keychain_group "$app_entitlements_after_path" "$RESIDENT_KEYCHAIN_GROUP"
/usr/bin/plutil -convert xml1 \
    -o "$signing_material_dir/app-before.normalized.plist" \
    "$app_entitlements_path"
/usr/bin/plutil -convert xml1 \
    -o "$signing_material_dir/app-after.normalized.plist" \
    "$app_entitlements_after_path"
if ! /usr/bin/cmp -s \
    "$signing_material_dir/app-before.normalized.plist" \
    "$signing_material_dir/app-after.normalized.plist"; then
    fail "re-signing changed the app entitlements"
fi
verify_signed_artifact \
    "$APP_BUNDLE" \
    "$BUNDLE_ID" \
    "$EXPECTED_TEAM_ID" \
    "$signing_identity" \
    "staged Hex app" \
    "$APP_CODE_SIGNING_REQUIREMENT"

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
        /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
        ;;
    --telemetry | telemetry)
        open_app
        /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
        ;;
    --verify | verify)
        test -x "$APP_BINARY"
        /usr/bin/plutil -lint "$APP_BUNDLE/Contents/Info.plist" >/dev/null
        verify_gateway_bundle
        verification_token="hex-verification-$$-$RANDOM"
        /usr/bin/open -n "$APP_BUNDLE" --args "$VERIFY_NO_CONNECT_ARGUMENT" "$verification_token"

        if ! verified_app_pid="$(wait_for_verified_app "$verification_token")"; then
            echo "staged $APP_NAME did not launch within five seconds" >&2
            exit 1
        fi
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

        echo "verified staged Debug app launch and packaged gateway layout at $APP_BUNDLE"
        ;;
esac
