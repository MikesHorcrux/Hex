import Foundation

public enum PersonalityProfileStoreError: Error, Equatable, LocalizedError, Sendable {
  case invalidFileURL
  case invalidMaximumBytes
  case malformedProfile
  case profileTooLarge
  case unsafeFile
  case lockFailure
  case encodingFailure
  case ioFailure

  public var errorDescription: String? {
    switch self {
    case .invalidFileURL:
      "The personality profile file URL is invalid."
    case .invalidMaximumBytes:
      "The personality profile size limit is invalid."
    case .malformedProfile:
      "The personality profile contains malformed or unsupported durable data."
    case .profileTooLarge:
      "The personality profile exceeds the allowed size."
    case .unsafeFile:
      "The personality profile path is not a private file owned by the current user."
    case .lockFailure:
      "The personality profile lock could not be acquired."
    case .encodingFailure:
      "The personality profile could not be encoded."
    case .ioFailure:
      "The personality profile could not be read or durably written."
    }
  }
}
