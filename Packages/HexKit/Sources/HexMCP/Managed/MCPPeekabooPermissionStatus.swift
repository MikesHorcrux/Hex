public struct MCPPeekabooPermissionStatus: Equatable, Sendable {
  public let accessibilityGranted: Bool
  public let screenRecordingGranted: Bool

  public var isGranted: Bool {
    accessibilityGranted && screenRecordingGranted
  }

  public init(
    accessibilityGranted: Bool,
    screenRecordingGranted: Bool
  ) {
    self.accessibilityGranted = accessibilityGranted
    self.screenRecordingGranted = screenRecordingGranted
  }
}
