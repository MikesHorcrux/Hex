import Foundation

struct GatewayClientConnectionAttemptID: Hashable, Sendable {
  let rawValue: UUID

  init() {
    rawValue = UUID()
  }
}
