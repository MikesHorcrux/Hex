import Foundation

struct GatewayClientStartAttemptID: Hashable, Sendable {
  let rawValue: UUID

  init() {
    rawValue = UUID()
  }
}
