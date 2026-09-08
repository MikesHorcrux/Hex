public struct MacApplicationSnapshot: Equatable, Sendable {
  public let bundleIdentifier: String
  public let localizedName: String
  public let processIdentifier: Int32
  public let isActive: Bool
  public let isHidden: Bool

  public init(
    bundleIdentifier: String,
    localizedName: String,
    processIdentifier: Int32,
    isActive: Bool,
    isHidden: Bool
  ) {
    self.bundleIdentifier = bundleIdentifier
    self.localizedName = localizedName
    self.processIdentifier = processIdentifier
    self.isActive = isActive
    self.isHidden = isHidden
  }
}
