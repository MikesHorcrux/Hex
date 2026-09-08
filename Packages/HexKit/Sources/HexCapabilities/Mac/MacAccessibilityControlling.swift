public protocol MacAccessibilityControlling: Sendable {
  func isTrusted(promptIfNeeded: Bool) async -> Bool

  func snapshot(
    bundleIdentifier: String,
    maximumDepth: Int,
    maximumElements: Int
  ) async throws -> MacAccessibilitySnapshot

  func perform(
    _ request: MacAccessibilityActionRequest
  ) async throws -> MacAccessibilityActionResult
}
