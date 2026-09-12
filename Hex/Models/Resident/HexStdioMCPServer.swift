import Foundation

struct HexStdioMCPServer: Identifiable, Equatable, Sendable {
  let serverID: String
  let executableURL: URL
  let arguments: [String]
  let workingDirectory: URL
  var isEnabled: Bool

  var id: String { serverID }
}
