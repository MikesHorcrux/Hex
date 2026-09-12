import Foundation
import Security

/// The team boundary comes from this process's validated code signature, never user defaults or
/// an environment variable. Unsigned and ad hoc processes have no resident signing identity.
public struct HexSigningIdentity: Equatable, Sendable {
  public let teamIdentifier: String

  public init?(teamIdentifier: String) {
    let bytes = Array(teamIdentifier.utf8)
    guard bytes.count == 10,
      bytes.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) })
    else { return nil }
    self.teamIdentifier = teamIdentifier
  }

  public var residentKeychainAccessGroup: String {
    "\(teamIdentifier).com.lunarmothstudios.Hex.resident"
  }

  public var applicationCodeSigningRequirement: String {
    "anchor apple generic and identifier \"com.lunarmothstudios.Hex\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
  }

  public static var current: Self? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
      SecCodeCheckValidity(code, [], nil) == errSecSuccess
    else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
      return nil
    }
    var information: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
      let values = information as? [String: Any],
      let team = values[kSecCodeInfoTeamIdentifier as String] as? String
    else { return nil }
    return Self(teamIdentifier: team)
  }
}
