import Foundation

struct HexHTTPMCPServer: Identifiable, Equatable, Sendable {
  let serverID: String
  let endpointURL: URL
  var isEnabled: Bool
  var requiresBearerToken = false
  /// Nil means Keychain availability could not be verified; it never means the token is missing.
  var hasStoredBearerToken: Bool? = false

  var id: String { serverID }
}
