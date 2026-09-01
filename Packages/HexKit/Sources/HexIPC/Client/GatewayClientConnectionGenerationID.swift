import Foundation

struct GatewayClientConnectionGenerationID: Hashable, Sendable {
  let rawValue: UUID

  init() {
    rawValue = UUID()
  }
}
