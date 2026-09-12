public struct MacAccessibilitySelector: Equatable, Sendable {
  public let path: String?
  public let identifier: String?
  public let role: String?
  public let title: String?
  public let occurrence: Int?

  public init(
    path: String? = nil,
    identifier: String? = nil,
    role: String? = nil,
    title: String? = nil,
    occurrence: Int? = nil
  ) {
    self.path = path
    self.identifier = identifier
    self.role = role
    self.title = title
    self.occurrence = occurrence
  }
}
