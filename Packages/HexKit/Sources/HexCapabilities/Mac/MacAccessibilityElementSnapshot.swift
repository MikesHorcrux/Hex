public struct MacAccessibilityElementSnapshot: Equatable, Sendable {
  public let path: String
  public let role: String
  public let subrole: String?
  public let title: String?
  public let label: String?
  public let value: String?
  public let identifier: String?
  public let isEnabled: Bool?
  public let isFocused: Bool?
  public let actions: [String]
  public let childCount: Int

  public init(
    path: String,
    role: String,
    subrole: String? = nil,
    title: String? = nil,
    label: String? = nil,
    value: String? = nil,
    identifier: String? = nil,
    isEnabled: Bool? = nil,
    isFocused: Bool? = nil,
    actions: [String] = [],
    childCount: Int = 0
  ) {
    self.path = path
    self.role = role
    self.subrole = subrole
    self.title = title
    self.label = label
    self.value = value
    self.identifier = identifier
    self.isEnabled = isEnabled
    self.isFocused = isFocused
    self.actions = actions
    self.childCount = childCount
  }
}
