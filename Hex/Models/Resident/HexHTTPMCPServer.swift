import Foundation

struct HexHTTPMCPServer: Identifiable, Equatable, Sendable {
  let serverID: String
  let endpointURL: URL
  var isEnabled: Bool

  var id: String { serverID }
}
