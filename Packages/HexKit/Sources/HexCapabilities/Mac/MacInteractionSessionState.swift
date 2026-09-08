public enum MacInteractionSessionState: Equatable, Sendable {
  case available
  case locked
  case unavailable

  func requireAvailable() throws {
    switch self {
    case .available: break
    case .locked: throw MacToolError.interactionSessionLocked
    case .unavailable: throw MacToolError.interactionSessionUnavailable
    }
  }
}
