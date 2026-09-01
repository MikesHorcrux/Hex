public enum MacAccessibilityAction: String, CaseIterable, Equatable, Sendable {
  case press
  case focus
  case setValue = "set_value"
}
