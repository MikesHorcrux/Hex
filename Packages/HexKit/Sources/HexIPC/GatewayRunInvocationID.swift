import Foundation

/// Distinguishes separate invocations that reuse the same externally supplied run identifier.
struct GatewayRunInvocationID: Equatable, Sendable {
  let rawValue: UUID

  init() {
    rawValue = UUID()
  }
}
