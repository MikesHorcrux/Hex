import Foundation

enum HexUnavailableResidentGatewayControlError: Error, Equatable, LocalizedError, Sendable {
  case unavailable

  var errorDescription: String? {
    "Resident gateway controls are unavailable until the gateway session is connected."
  }
}
