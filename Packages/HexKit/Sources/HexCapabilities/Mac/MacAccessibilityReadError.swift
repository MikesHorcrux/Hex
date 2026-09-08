import ApplicationServices

/// Structural AX failures contain only the requested attribute, generated path, and API status.
struct MacAccessibilityReadError: Error, Equatable, Sendable {
  enum Reason: String, Sendable {
    case requestFailed = "request_failed"
    case childrenNotExposed = "children_not_exposed"
    case invalidValue = "invalid_value"
  }

  let attribute = "AXChildren"
  let elementPath: String
  let axErrorCode: Int32
  let reason: Reason

  var isPermissionDenied: Bool { axErrorCode == AXError.apiDisabled.rawValue }
}
