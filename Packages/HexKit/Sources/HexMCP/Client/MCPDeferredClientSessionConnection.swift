import Foundation

struct MCPDeferredClientSessionConnection: Sendable {
  let id: UUID
  let session: any MCPClientSession
  var pendingConnect: Task<Void, any Error>?
  var isReady = false
}
