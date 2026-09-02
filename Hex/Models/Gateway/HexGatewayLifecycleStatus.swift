/// App-facing projection of SMAppService status. `.notFound` means ServiceManagement has no service
/// record; it does not prove that the bundled helper is absent. Activation readiness validates the
/// bundle independently before Hex offers registration.
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
      "Not registered"
    case .unavailable:
      "Unavailable"
    }
  }

  var isEnabled: Bool {
    self == .enabled
  }
}
