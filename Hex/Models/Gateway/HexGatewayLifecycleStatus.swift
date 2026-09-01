/// App-facing projection of SMAppService status. `.notFound` is intentionally distinct from
/// `.notRegistered`: it means the helper plist is not in the app bundle yet, so the UI can explain
/// that start-at-login is pending rather than claiming it is disabled by the user.
nonisolated enum HexGatewayLifecycleStatus: String, Equatable, Sendable {
  case unknown
  case enabled
  case notRegistered
  case requiresApproval
  case notFound
  case unavailable

  var label: String {
    switch self {
    case .unknown:
      "Checking…"
    case .enabled:
      "Enabled"
    case .notRegistered:
      "Off"
    case .requiresApproval:
      "Needs approval"
    case .notFound:
      "Pending helper bundle"
    case .unavailable:
      "Unavailable"
    }
  }

  var canChange: Bool {
    switch self {
    case .enabled, .notRegistered, .requiresApproval:
      true
    case .unknown, .notFound, .unavailable:
      false
    }
  }

  var isEnabled: Bool {
    self == .enabled
  }
}
