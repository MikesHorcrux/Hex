import Foundation

struct MCPPeekabooPermissionControllerPermission: Decodable, Sendable {
  let name: String
  let isGranted: Bool
}
