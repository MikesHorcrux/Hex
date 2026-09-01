import HexCore

/// The composition seam between gateway lifecycle policy and an agent runtime. Implementations must
/// durably create records before emitting them, emit exactly increasing per-run sequences beginning
/// at one, emit one terminal record, and propagate task cancellation after emitting `runCancelled`.
public protocol HexGatewayRunDriver: Sendable {
  func run(
    _ request: GatewayStartRunRequest,
    emit: @escaping @Sendable (AgentEventRecord) async throws -> Void
  ) async throws
}
