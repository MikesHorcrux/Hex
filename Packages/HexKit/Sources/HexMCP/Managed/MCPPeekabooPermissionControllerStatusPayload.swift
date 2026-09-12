import Foundation

struct MCPPeekabooPermissionControllerStatusPayload: Decodable, Sendable {
  let permissions: [MCPPeekabooPermissionControllerPermission]
}
