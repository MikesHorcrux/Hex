import HexCore
import HexIPC

/// Adapts the package's replay-aware client to the app protocol. Authorization routing remains an
/// injected closure because the transport milestone does not prescribe how a UI decision crosses
/// into the gateway's authorization provider.
nonisolated struct HexGatewayClientAdapter: HexAgentClient, Sendable {
  let client: HexGatewayClient
  private let authorizationHandler:
    (@Sendable (AuthorizationRequest, AuthorizationDecisionChoice) async throws -> Void)?

  init(
    client: HexGatewayClient,
    authorizationHandler:
      (@Sendable (AuthorizationRequest, AuthorizationDecisionChoice) async throws -> Void)? = nil
  ) {
    self.client = client
    self.authorizationHandler = authorizationHandler
  }

  func connect() async throws -> GatewayConnectionResult {
    try await client.connect()
  }

  func disconnect() async throws {
    try await client.disconnect()
  }

  func startRun(_ request: GatewayStartRunRequest) async throws -> GatewayStartRunResponse {
    try await client.startRun(request)
  }

  func eventRecords(
    for runID: AgentRunID,
    invocationID: GatewayRunInvocationID
  ) async throws -> AsyncThrowingStream<GatewayEventEnvelope, any Error> {
    try await client.eventRecords(for: runID, invocationID: invocationID)
  }

  func cancelRun(_ request: GatewayCancelRunRequest) async throws -> GatewayCancelRunResponse {
    try await client.cancelRun(request)
  }

  func shouldApply(_ envelope: GatewayEventEnvelope) async throws -> Bool {
    try await client.shouldApply(envelope)
  }

  func acknowledge(_ envelope: GatewayEventEnvelope) async throws {
    try await client.acknowledge(envelope)
  }

  func decideAuthorization(
    _ request: AuthorizationRequest,
    choice: AuthorizationDecisionChoice
  ) async throws {
    guard let authorizationHandler else {
      throw GatewayFailure(
        code: .transportUnavailable,
        message: "Authorization routing is not connected to this gateway yet."
      )
    }
    try await authorizationHandler(request, choice)
  }
}
