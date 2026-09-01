import Foundation

/// Default control route when no resident gateway client has been connected. It reports unavailable
/// state and rejects mutations instead of making a local UI toggle look like a remote change.
struct HexUnavailableResidentGatewayController: HexResidentGatewayControlling {
  enum ControlError: Error, Equatable, LocalizedError, Sendable {
    case unavailable

    var errorDescription: String? {
      "Resident gateway controls are unavailable until the gateway session is connected."
    }
  }

  func status() async throws -> HexResidentGatewayStatus {
    .unavailable
  }

  func pauseHeartbeats() async throws -> HexResidentGatewayStatus {
    throw ControlError.unavailable
  }

  func resumeHeartbeats() async throws -> HexResidentGatewayStatus {
    throw ControlError.unavailable
  }
}
