/// The Accessibility trust state reported by the process that actually performs native Mac
/// control. Transport availability is represented by an error so an unreachable gateway can
/// never be mistaken for a denied permission.
public enum GatewayAccessibilityPermissionStatus: String, Codable, Equatable, Sendable {
  case trusted
  case notTrusted
}
