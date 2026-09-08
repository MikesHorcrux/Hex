public struct MacAccessibilityActionResult: Equatable, Sendable {
  public let bundleIdentifier: String
  public let path: String
  public let action: MacAccessibilityAction
  public let observationID: String
  public let windowReference: String?

  public init(
    bundleIdentifier: String,
    path: String,
    action: MacAccessibilityAction,
    observationID: String = "",
    windowReference: String? = nil
  ) {
    self.bundleIdentifier = bundleIdentifier
    self.path = path
    self.action = action
    self.observationID = observationID
    self.windowReference = windowReference
  }
}
