import HexIPC

extension HexGatewayClientAdapter {
  func status() async throws -> GatewayResidentStatus {
    try await client.status()
  }

  func pauseHeartbeats() async throws -> GatewayResidentStatus {
    try await client.pauseHeartbeats()
  }

  func resumeHeartbeats() async throws -> GatewayResidentStatus {
    try await client.resumeHeartbeats()
  }
}
