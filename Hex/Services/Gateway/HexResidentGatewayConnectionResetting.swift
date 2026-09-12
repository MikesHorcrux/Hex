/// Invalidates the app's cached resident-gateway session before the service is restarted.
/// Implementations must leave the next operation able to establish a fresh connection.
nonisolated protocol HexResidentGatewayConnectionResetting: Sendable {
  func resetResidentGatewayConnection() async
}
