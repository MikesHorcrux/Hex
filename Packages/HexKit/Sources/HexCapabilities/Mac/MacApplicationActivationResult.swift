public struct MacApplicationActivationResult: Equatable, Sendable {
  public let bundleIdentifier: String
  public let wasRunning: Bool

  public init(bundleIdentifier: String, wasRunning: Bool) {
    self.bundleIdentifier = bundleIdentifier
    self.wasRunning = wasRunning
  }
}
