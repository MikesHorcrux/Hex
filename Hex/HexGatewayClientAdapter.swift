import HexCore
import HexIPC

/// Adapts the package's replay-aware client to the app protocol. Authorization routing is an
/// injected process boundary so a resident gateway can receive decisions over IPC without placing
/// a second broker in the app.
nonisolated struct HexGatewayClientAdapter: HexAgentClient, Sendable {
  let client: HexGatewayClient
  private let authorizationTransport: any HexAuthorizationDecisionSubmitting

  init(
    client: HexGatewayClient,
    authorizationTransport: any HexAuthorizationDecisionSubmitting =
      HexUnavailableAuthorizationDecisionTransport()
  ) {
    self.client = client
    self.authorizationTransport = authorizationTransport
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
    try await authorizationTransport.submit(request, choice: choice)
  }
}
