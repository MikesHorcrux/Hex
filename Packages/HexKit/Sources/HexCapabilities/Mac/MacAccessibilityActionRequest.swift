public struct MacAccessibilityActionRequest: Equatable, Sendable {
  public let bundleIdentifier: String
  public let selector: MacAccessibilitySelector
  public let action: MacAccessibilityAction
  public let value: String?

  public init(
    bundleIdentifier: String,
    selector: MacAccessibilitySelector,
    action: MacAccessibilityAction,
    value: String? = nil
  ) {
    self.bundleIdentifier = bundleIdentifier
    self.selector = selector
    self.action = action
    self.value = value
  }
}
