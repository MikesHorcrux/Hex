#!/usr/bin/env bash
# Validate signature-derived boundaries without launching Hex, contacting launchd, or reading secrets.
set -euo pipefail
readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly APP="${1:?usage: verify_signing.sh /path/to/Hex.app}"
readonly HELPER="$APP/Contents/Resources/HexGateway.app"
/usr/bin/codesign --verify --deep --strict "$APP"
readonly IDENTITY="$(/usr/bin/codesign -dvvv "$APP" 2>&1 | sed -n 's/^Authority=\(Apple Development: .*\)/\1/p' | head -1)"
[[ -n "$IDENTITY" ]] || { echo 'An Apple Development signed app is required.' >&2; exit 1; }
readonly TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
cat > "$TEMP/Probe.swift" <<'SWIFT'
import Foundation
import Security

@main
struct Probe {
  static func main() throws {
    if CommandLine.arguments.count == 1 {
      guard HexSigningIdentity.current == nil else { throw Failure.invalidBoundary }
      print("PASS: unsigned/ad hoc process has no trusted resident identity")
      return
    }
    guard let identity = HexSigningIdentity.current else { throw Failure.invalidBoundary }
    let app = CommandLine.arguments[1]
    let helper = CommandLine.arguments[2]
    guard matches(app, identity.applicationCodeSigningRequirement),
      matches(helper, "anchor apple generic and identifier \"com.lunarmothstudios.hex.gateway\" and certificate leaf[subject.OU] = \"\(identity.teamIdentifier)\""),
      let other = HexSigningIdentity(teamIdentifier: identity.teamIdentifier == "ZZZZZZZZZZ" ? "YYYYYYYYYY" : "ZZZZZZZZZZ"),
      !matches(app, other.applicationCodeSigningRequirement),
      !matches(app, "never")
    else { throw Failure.invalidBoundary }
    print("PASS: signed identity admits matching app/helper and rejects another team and unsigned policy")
    print("PASS: resident group derived from validated team: \(identity.residentKeychainAccessGroup)")
  }

  static func matches(_ path: String, _ expression: String) -> Bool {
    var code: SecStaticCode?
    var requirement: SecRequirement?
    guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
      let code,
      SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
      let requirement
    else { return false }
    return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
  }

  enum Failure: Error { case invalidBoundary }
}
SWIFT
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" xcrun swiftc \
    -swift-version 6 -strict-concurrency=complete \
    "$ROOT_DIR/Packages/HexKit/Sources/HexCore/Resident/HexSigningIdentity.swift" \
    "$TEMP/Probe.swift" -o "$TEMP/probe"
"$TEMP/probe"
/usr/bin/codesign --force --sign "$IDENTITY" --timestamp=none --options runtime "$TEMP/probe"
"$TEMP/probe" "$APP" "$HELPER"
