import HexCore
import HexIPC

/// The app-facing seam for a gateway-backed agent run. The UI depends on this small protocol so a
/// preview client can drive the same state machine without credentials, a running process, or an
/// XPC connection.
nonisolated protocol HexAgentClient: Sendable {
  func connect() async throws -> GatewayConnectionResult
  func disconnect() async throws
  func availableModels() async throws -> [ModelDescriptor]
  func readArtifact(_ request: GatewayArtifactReadRequest) async throws
    -> GatewayArtifactReadResponse

  func startRun(_ request: GatewayStartRunRequest) async throws -> GatewayStartRunResponse
  func eventRecords(
    for runID: AgentRunID,
    invocationID: GatewayRunInvocationID
  ) async throws -> AsyncThrowingStream<GatewayEventEnvelope, any Error>
  func cancelRun(_ request: GatewayCancelRunRequest) async throws -> GatewayCancelRunResponse
  func recoverRun(_ request: GatewayRunRecoveryRequest) async throws -> GatewayRunRecoveryResponse
  func readRunHistory(_ request: GatewayRunHistoryRequest) async throws -> GatewayRunHistoryPage
  func eventRecords(
    for runID: AgentRunID, invocationID: GatewayRunInvocationID, afterSequence: UInt64
  ) async throws -> AsyncThrowingStream<GatewayEventEnvelope, any Error>

  func shouldApply(_ envelope: GatewayEventEnvelope) async throws -> Bool
  func acknowledge(_ envelope: GatewayEventEnvelope) async throws

  func decideAuthorization(
    _ request: AuthorizationRequest,
    choice: AuthorizationDecisionChoice
  ) async throws
}
