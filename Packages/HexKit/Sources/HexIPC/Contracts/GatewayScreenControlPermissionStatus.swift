/// The two macOS privacy grants required by the resident process's screen-control tool. Transport
/// availability is represented by an error so an unreachable gateway can never be mistaken for a
/// denied permission.
public struct GatewayScreenControlPermissionStatus: Codable, Equatable, Sendable {
  public let accessibilityGranted: Bool
  public let screenRecordingGranted: Bool

  public init(
    accessibilityGranted: Bool,
    screenRecordingGranted: Bool
  ) {
    self.accessibilityGranted = accessibilityGranted
    self.screenRecordingGranted = screenRecordingGranted
  }

  public var isGranted: Bool {
    accessibilityGranted && screenRecordingGranted
  }
}
