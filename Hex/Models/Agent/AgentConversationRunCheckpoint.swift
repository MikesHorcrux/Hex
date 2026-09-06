import Foundation
import HexCore
import HexIPC

/// One immutable-request projection checkpoint, saved atomically with its owning conversation.
/// These are observation identities and pending requests, never persisted permission decisions.
nonisolated struct AgentConversationRunCheckpoint: Codable, Equatable, Sendable {
  let request: GatewayStartRunRequest
  var gatewayInstanceID: GatewayInstanceID?
  var invocationID: GatewayRunInvocationID?
  var appliedSequence: UInt64
  var firstEventID: AgentEventID?
  var streamingAssistantItemID: UUID?
  var pendingAuthorizations: [AuthorizationRequest]
  var hasToolEvidence: Bool
  var cancellationRequested: Bool

  nonisolated init(
    request: GatewayStartRunRequest,
    gatewayInstanceID: GatewayInstanceID? = nil,
    invocationID: GatewayRunInvocationID? = nil,
    appliedSequence: UInt64 = 0,
    firstEventID: AgentEventID? = nil,
    streamingAssistantItemID: UUID? = nil,
    pendingAuthorizations: [AuthorizationRequest] = [],
    hasToolEvidence: Bool = false,
    cancellationRequested: Bool = false
  ) {
    self.request = request
    self.gatewayInstanceID = gatewayInstanceID
    self.invocationID = invocationID
    self.appliedSequence = appliedSequence
    self.firstEventID = firstEventID
    self.streamingAssistantItemID = streamingAssistantItemID
    self.pendingAuthorizations = pendingAuthorizations
    self.hasToolEvidence = hasToolEvidence
    self.cancellationRequested = cancellationRequested
  }
}
