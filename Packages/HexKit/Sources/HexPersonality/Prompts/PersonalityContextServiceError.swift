import Foundation

public enum PersonalityContextServiceError: Error, Equatable, LocalizedError, Sendable {
  case profileUnavailable

  public var errorDescription: String? {
    switch self {
    case .profileUnavailable:
      "A personality profile has not been configured."
    }
  }
}
