#!/usr/bin/env bash
set -euo pipefail

readonly APP_BUNDLE="${1:-}"
readonly MARKETING_VERSION="${2:-}"
readonly BUILD_VERSION="${3:-}"
readonly SIGNING_IDENTITY="${4:-}"
readonly APP_BUNDLE_IDENTIFIER="${5:-}"
readonly APP_BINARY="${6:-}"
readonly EXPECTED_APP_BUNDLE_ID="com.lunarmothstudios.Hex"
readonly EXPECTED_TEAM_ID="5V5PZUN2HG"
readonly HELPER_BUNDLE_ID="com.lunarmothstudios.hex.gateway"
readonly HELPER_DISPLAY_NAME="Hex Agent"
readonly RESIDENT_KEYCHAIN_GROUP="5V5PZUN2HG.com.lunarmothstudios.Hex.resident"
readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly GATEWAY_BUILD_PATH="$ROOT_DIR/.build/HexGateway"
readonly GATEWAY_BUILD_LOCK="$ROOT_DIR/.build/HexGateway.lock"
readonly GATEWAY_APP_BUNDLE="$APP_BUNDLE/Contents/Resources/HexGateway.app"
readonly GATEWAY_BINARY="$GATEWAY_APP_BUNDLE/Contents/MacOS/HexGateway"
readonly GATEWAY_INFO_PLIST="$GATEWAY_APP_BUNDLE/Contents/Info.plist"
readonly GATEWAY_PROFILE="$GATEWAY_APP_BUNDLE/Contents/embedded.provisionprofile"
readonly APP_PROFILE="$APP_BUNDLE/Contents/embedded.provisionprofile"
readonly LAUNCH_AGENT_SOURCE="$ROOT_DIR/Resources/LaunchAgent/com.lunarmothstudios.hex.gateway.plist"
readonly BUNDLED_LAUNCH_AGENT="$APP_BUNDLE/Contents/Library/LaunchAgents/com.lunarmothstudios.hex.gateway.plist"
readonly XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

temporary_directory=""
helper_entitlements=""
helper_signed_entitlements=""
helper_info_plist=""

fail() {
    echo "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "$temporary_directory" && -d "$temporary_directory" ]]; then
        /bin/rm -rf "$temporary_directory"
    fi
}

trap cleanup EXIT

validate_arguments() {
    [[ -d "$APP_BUNDLE" ]] || fail "Hex app bundle is missing at $APP_BUNDLE"
    [[ "$APP_BUNDLE_IDENTIFIER" == "$EXPECTED_APP_BUNDLE_ID" ]] \
        || fail "refusing to stage a gateway into unexpected app identifier $APP_BUNDLE_IDENTIFIER"
    [[ -x "$APP_BINARY" ]] || fail "Hex executable is missing at $APP_BINARY"
    [[ "$MARKETING_VERSION" =~ ^[0-9]+([.][0-9]+)*$ ]] \
        || fail "invalid Hex marketing version: $MARKETING_VERSION"
    [[ "$BUILD_VERSION" =~ ^[0-9]+$ ]] || fail "invalid Hex build version: $BUILD_VERSION"
    [[ -n "$SIGNING_IDENTITY" && "$SIGNING_IDENTITY" != "-" ]] \
        || fail "Xcode did not provide a signing identity for HexGateway"
    [[ -f "$APP_PROFILE" ]] \
        || fail "Hex has no embedded development provisioning profile at $APP_PROFILE"
    [[ -f "$LAUNCH_AGENT_SOURCE" ]] \
        || fail "Hex LaunchAgent definition is missing at $LAUNCH_AGENT_SOURCE"
}

validate_single_keychain_group() {
    local entitlements="$1"
    local expected_group="$2"
    local actual_group
    actual_group="$(/usr/bin/plutil -extract keychain-access-groups.0 raw -o - "$entitlements" 2>/dev/null)" \
        || fail "missing keychain-access-groups in $entitlements"
    [[ "$actual_group" == "$expected_group" ]] \
        || fail "unexpected keychain access group in $entitlements: $actual_group"
    if /usr/bin/plutil -extract keychain-access-groups.1 raw -o - "$entitlements" >/dev/null 2>&1; then
        fail "more than one keychain access group is present in $entitlements"
    fi
}

validate_profile() {
    local decoded_profile="$temporary_directory/profile.plist"
    local application_identifier
    local keychain_group
    local team_identifier
    /usr/bin/security cms -D -i "$APP_PROFILE" -o "$decoded_profile" >/dev/null 2>&1 \
        || fail "could not decode Hex's development provisioning profile"
    application_identifier="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$decoded_profile" 2>/dev/null)" \
        || fail "Hex's development profile has no application identifier"
    case "$application_identifier" in
        "${EXPECTED_TEAM_ID}.*" | "${EXPECTED_TEAM_ID}.${HELPER_BUNDLE_ID}") ;;
        *) fail "Hex's development profile does not authorize HexGateway" ;;
    esac
    keychain_group="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:keychain-access-groups:0' "$decoded_profile" 2>/dev/null)" \
        || fail "Hex's development profile has no keychain access group"
    case "$keychain_group" in
        "${EXPECTED_TEAM_ID}.*" | "$RESIDENT_KEYCHAIN_GROUP") ;;
        *) fail "Hex's development profile does not authorize the resident keychain group" ;;
    esac
    team_identifier="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$decoded_profile" 2>/dev/null)" \
        || fail "Hex's development profile has no team identifier"
    [[ "$team_identifier" == "$EXPECTED_TEAM_ID" ]] \
        || fail "unexpected team identifier in Hex's development profile: $team_identifier"
}

write_helper_metadata() {
    /bin/cat > "$helper_entitlements" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.application-identifier</key>
    <string>${EXPECTED_TEAM_ID}.${HELPER_BUNDLE_ID}</string>
    <key>com.apple.developer.team-identifier</key>
    <string>${EXPECTED_TEAM_ID}</string>
    <key>keychain-access-groups</key>
    <array>
        <string>${RESIDENT_KEYCHAIN_GROUP}</string>
    </array>
</dict>
</plist>
EOF
    /bin/cat > "$helper_info_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>HexGateway</string>
    <key>CFBundleIdentifier</key>
    <string>${HELPER_BUNDLE_ID}</string>
    <key>CFBundleDisplayName</key>
    <string>${HELPER_DISPLAY_NAME}</string>
    <key>CFBundleName</key>
    <string>${HELPER_DISPLAY_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${MARKETING_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_VERSION}</string>
    <key>LSBackgroundOnly</key>
    <true/>
</dict>
</plist>
EOF
    /usr/bin/plutil -lint "$helper_entitlements" >/dev/null
    /usr/bin/plutil -lint "$helper_info_plist" >/dev/null
    validate_single_keychain_group "$helper_entitlements" "$RESIDENT_KEYCHAIN_GROUP"
}

build_gateway() {
    DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" /usr/bin/xcrun swift build \
        --package-path "$ROOT_DIR/Packages/HexKit" \
        --scratch-path "$GATEWAY_BUILD_PATH" \
        --product HexGateway \
        --configuration debug \
        -j 1
}

validate_matching_architectures() {
    local app_architectures
    local helper_architectures
    app_architectures="$(/usr/bin/lipo -archs "$APP_BINARY")" \
        || fail "could not inspect Hex executable architectures"
    helper_architectures="$(/usr/bin/lipo -archs "$GATEWAY_BINARY")" \
        || fail "could not inspect HexGateway executable architectures"
    [[ "$helper_architectures" == "$app_architectures" ]] \
        || fail "HexGateway architectures ($helper_architectures) do not match Hex ($app_architectures)"
}

verify_staged_gateway() {
    [[ -x "$GATEWAY_BINARY" ]] || fail "staged HexGateway executable is missing"
    [[ -f "$GATEWAY_INFO_PLIST" ]] || fail "staged HexGateway Info.plist is missing"
    [[ -f "$GATEWAY_PROFILE" ]] || fail "staged HexGateway profile is missing"
    [[ -f "$BUNDLED_LAUNCH_AGENT" ]] || fail "staged HexGateway LaunchAgent is missing"
    /usr/bin/plutil -lint "$GATEWAY_INFO_PLIST" >/dev/null
    /usr/bin/plutil -lint "$BUNDLED_LAUNCH_AGENT" >/dev/null
    [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$GATEWAY_INFO_PLIST")" == "$HELPER_BUNDLE_ID" ]] \
        || fail "staged HexGateway has an unexpected bundle identifier"
    [[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$GATEWAY_INFO_PLIST")" == "$MARKETING_VERSION" ]] \
        || fail "staged HexGateway has a stale marketing version"
    [[ "$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$GATEWAY_INFO_PLIST")" == "$BUILD_VERSION" ]] \
        || fail "staged HexGateway has a stale build version"
    [[ "$(/usr/bin/plutil -extract LSBackgroundOnly raw -o - "$GATEWAY_INFO_PLIST")" == "true" ]] \
        || fail "staged HexGateway is not background-only"
    [[ "$(/usr/bin/plutil -extract BundleProgram raw -o - "$BUNDLED_LAUNCH_AGENT")" == "Contents/Resources/HexGateway.app/Contents/MacOS/HexGateway" ]] \
        || fail "staged LaunchAgent has an unexpected BundleProgram"
    /usr/bin/cmp -s "$LAUNCH_AGENT_SOURCE" "$BUNDLED_LAUNCH_AGENT" \
        || fail "staged LaunchAgent differs from the repository definition"
    /usr/bin/codesign --verify --strict "$GATEWAY_APP_BUNDLE" >/dev/null \
        || fail "staged HexGateway signature is invalid"
    /usr/bin/codesign -d --entitlements :- "$GATEWAY_APP_BUNDLE" > "$helper_signed_entitlements" 2>/dev/null \
        || fail "could not read staged HexGateway entitlements"
    validate_single_keychain_group "$helper_signed_entitlements" "$RESIDENT_KEYCHAIN_GROUP"
    local signing_details
    local signed_identifier
    local signed_team
    signing_details="$(/usr/bin/codesign -dvvv "$GATEWAY_APP_BUNDLE" 2>&1)"
    signed_identifier="$(/usr/bin/printf '%s\n' "$signing_details" | /usr/bin/sed -n 's/^Identifier=//p' | /usr/bin/head -n 1)"
    signed_team="$(/usr/bin/printf '%s\n' "$signing_details" | /usr/bin/sed -n 's/^TeamIdentifier=//p' | /usr/bin/head -n 1)"
    [[ "$signed_identifier" == "$HELPER_BUNDLE_ID" ]] \
        || fail "signed HexGateway has unexpected identifier $signed_identifier"
    [[ "$signed_team" == "$EXPECTED_TEAM_ID" ]] \
        || fail "signed HexGateway has unexpected team $signed_team"
    [[ "$signing_details" == *"(runtime)"* ]] || fail "signed HexGateway lacks hardened runtime"
}

validate_arguments
/bin/mkdir -p "$ROOT_DIR/.build"
exec 9>"$GATEWAY_BUILD_LOCK"
if ! /usr/bin/lockf -s -t 60 9; then
    fail "another HexGateway build is using $GATEWAY_BUILD_PATH"
fi
temporary_directory="$(/usr/bin/mktemp -d "$ROOT_DIR/.build/hex-gateway-stage.XXXXXX")" \
    || fail "could not create HexGateway staging directory"
helper_entitlements="$temporary_directory/HexGateway.entitlements"
helper_signed_entitlements="$temporary_directory/HexGateway.signed.entitlements"
helper_info_plist="$temporary_directory/HexGateway-Info.plist"
validate_profile
write_helper_metadata
build_gateway
gateway_bin_path="$({
    DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" /usr/bin/xcrun swift build \
        --package-path "$ROOT_DIR/Packages/HexKit" \
        --scratch-path "$GATEWAY_BUILD_PATH" \
        --product HexGateway \
        --configuration debug \
        --show-bin-path
})"
[[ -x "$gateway_bin_path/HexGateway" ]] \
    || fail "built HexGateway executable is missing at $gateway_bin_path/HexGateway"

/bin/rm -rf "$GATEWAY_APP_BUNDLE"
/bin/mkdir -p "$(dirname "$GATEWAY_BINARY")" "$(dirname "$BUNDLED_LAUNCH_AGENT")"
/usr/bin/ditto "$gateway_bin_path/HexGateway" "$GATEWAY_BINARY"
/bin/chmod 0755 "$GATEWAY_BINARY"
/bin/cp "$helper_info_plist" "$GATEWAY_INFO_PLIST"
/bin/cp "$APP_PROFILE" "$GATEWAY_PROFILE"
/bin/cp "$LAUNCH_AGENT_SOURCE" "$BUNDLED_LAUNCH_AGENT"
/bin/chmod 0644 "$BUNDLED_LAUNCH_AGENT"
validate_matching_architectures

/usr/bin/codesign \
    --force \
    --sign "$SIGNING_IDENTITY" \
    --timestamp=none \
    --options runtime \
    --identifier "$HELPER_BUNDLE_ID" \
    --entitlements "$helper_entitlements" \
    "$GATEWAY_APP_BUNDLE"
verify_staged_gateway
echo "staged current HexGateway in $APP_BUNDLE"
