@preconcurrency import Foundation

struct GatewayXPCEventSinkBridgePendingAcknowledgement {
  let id: UUID
  let continuation: CheckedContinuation<Void, any Error>
  let timer: Task<Void, Never>
}
