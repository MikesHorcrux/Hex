import Foundation

enum HexPersonalityServiceError: Error, Equatable, LocalizedError, Sendable {
  case unavailable

  var errorDescription: String? {
    switch self {
    case .unavailable:
      "Personality and personal-memory settings are unavailable in this build."
    }
  }
}
