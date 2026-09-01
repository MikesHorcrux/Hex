/// The small status vocabulary a control surface needs from the resident gateway. Runtime details
/// remain behind the gateway protocol; the app only renders lifecycle state and whether pausing is
/// actually available.
nonisolated enum HexResidentGatewayStatus: String, Equatable, Sendable {
  case unavailable
  case idle
  case active
  case paused

  var label: String {
    switch self {
    case .unavailable:
      "Unavailable"
    case .idle:
      "Idle"
    case .active:
      "Active"
    case .paused:
      "Paused"
    }
  }

  var isAvailable: Bool {
    self != .unavailable
  }

  var isPaused: Bool {
    self == .paused
  }

  static let heartbeatControlDetail =
    "Pausing affects scheduled heartbeats only; an interactive task already running will continue."
}
