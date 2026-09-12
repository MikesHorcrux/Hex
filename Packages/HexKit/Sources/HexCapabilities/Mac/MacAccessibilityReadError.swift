import ApplicationServices

/// Structural AX failures contain only the requested attribute, generated path, and API status.
struct MacAccessibilityReadError: Error, Equatable, Sendable {
  let attribute = "AXChildren"
  let elementPath: String
  let axErrorCode: Int32
  let reason: MacAccessibilityReadErrorReason

  var isPermissionDenied: Bool { axErrorCode == AXError.apiDisabled.rawValue }
}
