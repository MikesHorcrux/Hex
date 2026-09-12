import Foundation

struct MCPPeekabooPermissionControllerStatusResponse: Decodable, Sendable {
  let success: Bool
  let data: MCPPeekabooPermissionControllerStatusPayload
}
