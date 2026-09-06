#!/usr/bin/env bash
set -euo pipefail

readonly MODE="${1:-run}"
readonly APP_NAME="Hex"
readonly BUNDLE_ID="com.lunarmothstudios.Hex"
readonly EXPECTED_TEAM_ID="5V5PZUN2HG"
readonly HELPER_BUNDLE_ID="com.lunarmothstudios.hex.gateway"
readonly HELPER_DISPLAY_NAME="Hex Agent"
readonly RESIDENT_KEYCHAIN_GROUP="5V5PZUN2HG.com.lunarmothstudios.Hex.resident"
readonly APP_CODE_SIGNING_REQUIREMENT='anchor apple generic and identifier "com.lunarmothstudios.Hex" and certificate leaf[subject.OU] = "5V5PZUN2HG"'
readonly VERIFY_NO_CONNECT_ARGUMENT="--hex-verify-no-connect"
readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_PATH="$ROOT_DIR/Hex.xcodeproj"
readonly XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
readonly CANONICAL_BUILD_DIR="$(
    DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" /usr/bin/xcodebuild \
        -project "$PROJECT_PATH" \
        -scheme "$APP_NAME" \
        -configuration Debug \
        -destination "platform=macOS" \
        -showBuildSettings \
        -json \
        2>/dev/null \
        | /usr/bin/plutil -extract 0.buildSettings.TARGET_BUILD_DIR raw -o - -
)"
readonly APP_BUNDLE="$CANONICAL_BUILD_DIR/$APP_NAME.app"
readonly BUILD_APP="$APP_BUNDLE"
readonly APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
readonly APP_INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
readonly GATEWAY_APP_BUNDLE="$APP_BUNDLE/Contents/Resources/HexGateway.app"
readonly GATEWAY_BUNDLE_BINARY="$GATEWAY_APP_BUNDLE/Contents/MacOS/HexGateway"
readonly GATEWAY_APP_INFO_PLIST="$GATEWAY_APP_BUNDLE/Contents/Info.plist"
readonly GATEWAY_APP_PROFILE="$GATEWAY_APP_BUNDLE/Contents/embedded.provisionprofile"
readonly GATEWAY_BUNDLE_PROGRAM="Contents/Resources/HexGateway.app/Contents/MacOS/HexGateway"
readonly BUNDLED_LAUNCH_AGENT="$APP_BUNDLE/Contents/Library/LaunchAgents/com.lunarmothstudios.hex.gateway.plist"
readonly LAUNCH_AGENT_SOURCE="$ROOT_DIR/Resources/LaunchAgent/com.lunarmothstudios.hex.gateway.plist"
readonly LAUNCHD_SERVICE_TARGET="gui/$(/usr/bin/id -u)/$HELPER_BUNDLE_ID"
verified_app_pid=""
signing_material_dir=""
app_entitlements_path=""
helper_entitlements_path=""
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

validate_helper_entitlements() {
    local entitlements="$1"
    local actual_application_identifier
    local actual_team_identifier

    actual_application_identifier="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "$entitlements" 2>/dev/null)" \
        || fail "missing application identifier in $entitlements"
    if [[ "$actual_application_identifier" != "${EXPECTED_TEAM_ID}.${HELPER_BUNDLE_ID}" ]]; then
        fail "unexpected helper application identifier in $entitlements: $actual_application_identifier"
    fi
    actual_team_identifier="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "$entitlements" 2>/dev/null)" \
        || fail "missing team identifier in $entitlements"
    if [[ "$actual_team_identifier" != "$EXPECTED_TEAM_ID" ]]; then
        fail "unexpected helper team identifier in $entitlements: $actual_team_identifier"
    fi
    validate_single_keychain_group "$entitlements" "$RESIDENT_KEYCHAIN_GROUP"
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
        "$APP_BINARY" | "$APP_BINARY "* | */Hex.app/Contents/MacOS/Hex | */Hex.app/Contents/MacOS/Hex\ *)
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

loaded_gateway_inode_for_pid() {
    local candidate_pid="$1"

    case "$candidate_pid" in
        "" | *[!0-9]*)
            return 1
            ;;
    esac

    /usr/sbin/lsof -a -p "$candidate_pid" -d txt -F in 2>/dev/null \
        | /usr/bin/awk -v expected_path="n$GATEWAY_BUNDLE_BINARY" '
            /^i/ { inode = substr($0, 2); next }
            $0 == expected_path { print inode; exit }
        '
}

refresh_registered_gateway() {
    local service_snapshot
    local registered_parent
    local registered_program
    local running_pid
    local loaded_inode
    local bundled_inode
    local attempt=0

    if ! service_snapshot="$(/bin/launchctl print "$LAUNCHD_SERVICE_TARGET" 2>/dev/null)"; then
        return 0
    fi

    registered_parent="$(
        /usr/bin/printf '%s\n' "$service_snapshot" \
            | /usr/bin/sed -n 's/^[[:space:]]*parent bundle identifier = //p' \
            | /usr/bin/head -n 1
    )"
    registered_program="$(
        /usr/bin/printf '%s\n' "$service_snapshot" \
            | /usr/bin/sed -n 's/^[[:space:]]*program identifier = \([^ ]*\).*/\1/p' \
            | /usr/bin/head -n 1
    )"
    if [[ "$registered_parent" != "$BUNDLE_ID" || "$registered_program" != "$GATEWAY_BUNDLE_PROGRAM" ]]; then
        fail "the registered Hex Agent does not belong to the canonical $BUNDLE_ID bundle"
    fi

    /bin/launchctl kickstart -k "$LAUNCHD_SERVICE_TARGET" \
        || fail "could not refresh the registered Hex Agent"
    bundled_inode="$(/usr/bin/stat -f '%i' "$GATEWAY_BUNDLE_BINARY")" \
        || fail "could not inspect the canonical Hex Agent executable"

    while ((attempt < 20)); do
        service_snapshot="$(/bin/launchctl print "$LAUNCHD_SERVICE_TARGET" 2>/dev/null || true)"
        running_pid="$(
            /usr/bin/printf '%s\n' "$service_snapshot" \
                | /usr/bin/sed -n 's/^[[:space:]]*pid = //p' \
                | /usr/bin/head -n 1
        )"
        loaded_inode="$(loaded_gateway_inode_for_pid "$running_pid" || true)"
        if [[ -n "$loaded_inode" && "$loaded_inode" == "$bundled_inode" ]]; then
            echo "refreshed the registered Hex Agent from $GATEWAY_APP_BUNDLE"
            return 0
        fi
        /bin/sleep 0.25
        attempt=$((attempt + 1))
    done

    fail "the registered Hex Agent did not load the canonical bundled executable"
}

verify_no_test_harness() {
    local test_bundle

    test_bundle="$(
        /usr/bin/find "$APP_BUNDLE/Contents" -type d -name '*.xctest' -print -quit 2>/dev/null \
            || true
    )"
    if [[ -n "$test_bundle" ]]; then
        fail "the canonical Hex app still contains a test bundle: $test_bundle"
    fi

    for test_artifact in \
        "$APP_BUNDLE/Contents/Frameworks/XCTest.framework" \
        "$APP_BUNDLE/Contents/Frameworks/XCTestCore.framework" \
        "$APP_BUNDLE/Contents/Frameworks/XCUIAutomation.framework" \
        "$APP_BUNDLE/Contents/Frameworks/libXCTestBundleInject.dylib" \
        "$APP_BUNDLE/Contents/Frameworks/libXCTestSwiftSupport.dylib"
    do
        if [[ -e "$test_artifact" ]]; then
            fail "the canonical Hex app still contains test instrumentation: $test_artifact"
        fi
    done
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
    clean build \
    -project "$PROJECT_PATH" \
    -scheme "$APP_NAME" \
    -configuration Debug \
    -destination "platform=macOS" \
    -jobs 1

if [[ ! -d "$BUILD_APP" ]]; then
    echo "built app was not found at $BUILD_APP" >&2
    exit 1
fi

/bin/mkdir -p "$ROOT_DIR/.build"
signing_material_dir="$(/usr/bin/mktemp -d "$ROOT_DIR/.build/hex-signing.XXXXXX")" \
    || fail "could not create temporary signing material directory"
app_entitlements_path="$signing_material_dir/app.entitlements"
helper_entitlements_path="$signing_material_dir/helper.entitlements"

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

verify_gateway_bundle() {
    if [[ ! -f "$APP_INFO_PLIST" ]]; then
        echo "packaged Hex Info.plist is missing at $APP_INFO_PLIST" >&2
        return 1
    fi
    if [[ ! -d "$GATEWAY_APP_BUNDLE" ]]; then
        echo "packaged HexGateway app bundle is missing at $GATEWAY_APP_BUNDLE" >&2
        return 1
    fi
    if [[ ! -x "$GATEWAY_BUNDLE_BINARY" ]]; then
        echo "packaged HexGateway helper is not executable at $GATEWAY_BUNDLE_BINARY" >&2
        return 1
    fi
    if [[ ! -f "$GATEWAY_APP_INFO_PLIST" ]]; then
        echo "packaged HexGateway Info.plist is missing at $GATEWAY_APP_INFO_PLIST" >&2
        return 1
    fi
    if [[ ! -f "$GATEWAY_APP_PROFILE" ]]; then
        echo "packaged HexGateway provisioning profile is missing at $GATEWAY_APP_PROFILE" >&2
        return 1
    fi
    /usr/bin/plutil -lint "$GATEWAY_APP_INFO_PLIST" >/dev/null
    local helper_identifier
    local helper_executable
    local helper_display_name
    local helper_background_only
    local helper_marketing_version
    local helper_build_version
    local app_marketing_version
    local app_build_version
    helper_identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$GATEWAY_APP_INFO_PLIST")"
    if [[ "$helper_identifier" != "$HELPER_BUNDLE_ID" ]]; then
        echo "HexGateway CFBundleIdentifier must be $HELPER_BUNDLE_ID" >&2
        return 1
    fi
    helper_executable="$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$GATEWAY_APP_INFO_PLIST")"
    if [[ "$helper_executable" != "HexGateway" ]]; then
        echo "HexGateway CFBundleExecutable must be HexGateway" >&2
        return 1
    fi
    helper_display_name="$(/usr/bin/plutil -extract CFBundleDisplayName raw -o - "$GATEWAY_APP_INFO_PLIST")"
    if [[ "$helper_display_name" != "$HELPER_DISPLAY_NAME" ]]; then
        echo "HexGateway CFBundleDisplayName must be $HELPER_DISPLAY_NAME" >&2
        return 1
    fi
    helper_background_only="$(/usr/bin/plutil -extract LSBackgroundOnly raw -o - "$GATEWAY_APP_INFO_PLIST")"
    if [[ "$helper_background_only" != "true" ]]; then
        echo "HexGateway LSBackgroundOnly must be true" >&2
        return 1
    fi
    helper_marketing_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$GATEWAY_APP_INFO_PLIST")"
    helper_build_version="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$GATEWAY_APP_INFO_PLIST")"
    app_marketing_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$APP_INFO_PLIST")"
    app_build_version="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$APP_INFO_PLIST")"
    if [[ "$helper_marketing_version" != "$app_marketing_version" ]]; then
        echo "HexGateway marketing version $helper_marketing_version does not match Hex $app_marketing_version" >&2
        return 1
    fi
    if [[ "$helper_build_version" != "$app_build_version" ]]; then
        echo "HexGateway build version $helper_build_version does not match Hex $app_build_version" >&2
        return 1
    fi
    if [[ ! -f "$LAUNCH_AGENT_SOURCE" ]]; then
        echo "bundle-ready LaunchAgent plist is missing at $LAUNCH_AGENT_SOURCE" >&2
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
    if [[ "$bundle_program" != "$GATEWAY_BUNDLE_PROGRAM" ]]; then
        echo "LaunchAgent BundleProgram must be $GATEWAY_BUNDLE_PROGRAM" >&2
        return 1
    fi
    mach_services="$(/usr/bin/plutil -extract MachServices json -o - "$BUNDLED_LAUNCH_AGENT")"
    if [[ "$mach_services" != "{\"$HELPER_BUNDLE_ID\":true}" ]]; then
        echo "LaunchAgent MachServices must contain only $HELPER_BUNDLE_ID=true" >&2
        return 1
    fi
    if ! /usr/bin/cmp -s "$LAUNCH_AGENT_SOURCE" "$BUNDLED_LAUNCH_AGENT"; then
        echo "packaged LaunchAgent differs from the repository definition" >&2
        return 1
    fi
}

verify_gateway_bundle

verify_signed_artifact \
    "$GATEWAY_APP_BUNDLE" \
    "$HELPER_BUNDLE_ID" \
    "$EXPECTED_TEAM_ID" \
    "$signing_identity" \
    "HexGateway helper app"
if ! /usr/bin/codesign --verify --strict "$GATEWAY_BUNDLE_BINARY" >/dev/null; then
    fail "the HexGateway executable did not pass strict verification"
fi
extract_entitlements "$GATEWAY_APP_BUNDLE" "$helper_entitlements_path"
validate_helper_entitlements "$helper_entitlements_path"
extract_entitlements "$APP_BUNDLE" "$app_entitlements_path"
validate_single_keychain_group "$app_entitlements_path" "$RESIDENT_KEYCHAIN_GROUP"
verify_no_test_harness
verify_signed_artifact \
    "$APP_BUNDLE" \
    "$BUNDLE_ID" \
    "$EXPECTED_TEAM_ID" \
    "$signing_identity" \
    "staged Hex app" \
    "$APP_CODE_SIGNING_REQUIREMENT"
if ! /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE" >/dev/null; then
    fail "the staged Hex app and nested helper signatures did not pass deep verification"
fi

open_app() {
    /usr/bin/open "$APP_BUNDLE"
}

case "$MODE" in
    --verify | verify)
        ;;
    *)
        # Keep the user's existing SMAppService choice, but replace any running older helper with
        # the just-built executable from this exact canonical bundle before the UI connects.
        refresh_registered_gateway
        ;;
esac

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
        /usr/bin/open "$APP_BUNDLE" --args "$VERIFY_NO_CONNECT_ARGUMENT" "$verification_token"

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
