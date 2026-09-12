enum AgentConnectionState: String, Sendable {
  case disconnected
  case connecting
  case connected

  var label: String {
    switch self {
    case .disconnected:
      "Disconnected"
    case .connecting:
      "Connecting"
    case .connected:
      "Connected"
    }
  }
}
