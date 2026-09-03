/// UI state for the resident agent's macOS Accessibility permission. An unavailable gateway is
/// deliberately distinct from a reachable gateway that reports no permission.
nonisolated enum HexAccessibilityPermissionState: Equatable, Sendable {
  case unchecked
  case checking
  case trusted
  case notTrusted
  case requestSent
  case gatewayUnavailable
  case failed(String)

  var hasVerifiedGateway: Bool {
    switch self {
    case .trusted, .notTrusted, .requestSent:
      true
    case .unchecked, .checking, .gatewayUnavailable, .failed:
      false
    }
  }
}
