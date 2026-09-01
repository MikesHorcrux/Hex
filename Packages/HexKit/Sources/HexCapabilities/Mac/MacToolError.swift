public enum MacToolError: Error, Equatable, Sendable {
  case invalidArguments
  case authorizationRequired
  case authorizationStateUnavailable
  case applicationNotFound
  case activationFailed
  case openURLFailed
  case accessibilityPermissionRequired
  case accessibilityObservationFailed
  case accessibilityElementNotFound
  case accessibilityElementAmbiguous
  case accessibilityActionUnsupported
  case accessibilityActionFailed
}
