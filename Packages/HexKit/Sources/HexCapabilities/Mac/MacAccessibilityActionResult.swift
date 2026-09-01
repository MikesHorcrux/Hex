public struct MacAccessibilityActionResult: Equatable, Sendable {
  public let bundleIdentifier: String
  public let path: String
  public let action: MacAccessibilityAction

  public init(
    bundleIdentifier: String,
    path: String,
    action: MacAccessibilityAction
  ) {
    self.bundleIdentifier = bundleIdentifier
    self.path = path
    self.action = action
  }
}
