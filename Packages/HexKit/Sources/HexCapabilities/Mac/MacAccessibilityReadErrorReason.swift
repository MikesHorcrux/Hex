import ApplicationServices

enum MacAccessibilityReadErrorReason: String, Sendable {
  case requestFailed = "request_failed"
  case childrenNotExposed = "children_not_exposed"
  case invalidValue = "invalid_value"
}
