/// Control boundary for a gateway that outlives the app window. Implementations must use the same
/// authenticated gateway session as interactive runs; they must not create a second connection.
nonisolated protocol HexResidentGatewayControlling: Sendable {
  func status() async throws -> HexResidentGatewayStatus
  func pauseHeartbeats() async throws -> HexResidentGatewayStatus
  func resumeHeartbeats() async throws -> HexResidentGatewayStatus
}
