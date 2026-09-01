/// Default control route while the resident gateway's status/pause IPC is not yet bundled. It
/// reports unavailable state and rejects mutations instead of making a local UI toggle look like a
/// remote gateway change.
struct HexUnavailableResidentGatewayController: HexResidentGatewayControlling {
  enum ControlError: Error, Equatable, LocalizedError, Sendable {
    case unavailable

    var errorDescription: String? {
      "Resident gateway controls are not available until the control IPC is installed."
    }
  }

  func status() async throws -> HexResidentGatewayStatus {
    .unavailable
  }

  func setPaused(_ paused: Bool) async throws -> HexResidentGatewayStatus {
    _ = paused
    throw ControlError.unavailable
  }
}
