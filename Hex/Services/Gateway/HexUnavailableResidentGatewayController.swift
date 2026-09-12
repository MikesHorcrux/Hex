import Foundation

/// Default control route when no resident gateway client has been connected. It reports unavailable
/// state and rejects mutations instead of making a local UI toggle look like a remote change.
struct HexUnavailableResidentGatewayController: HexResidentGatewayControlling {
  func status() async throws -> HexResidentGatewayStatus {
    .unavailable
  }

  func pauseHeartbeats() async throws -> HexResidentGatewayStatus {
    throw HexUnavailableResidentGatewayControlError.unavailable
  }

  func resumeHeartbeats() async throws -> HexResidentGatewayStatus {
    throw HexUnavailableResidentGatewayControlError.unavailable
  }
}
