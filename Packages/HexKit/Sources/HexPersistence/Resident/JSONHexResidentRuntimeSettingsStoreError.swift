import Foundation

/// Safe, non-secret failures raised by the resident settings file store.
public enum JSONHexResidentRuntimeSettingsStoreError: Error, Equatable, LocalizedError, Sendable {
  case invalidFileURL
  case invalidMaximumBytes
  case malformedSettings
  case settingsTooLarge
  case unsafeFile
  case lockFailure
  case encodingFailure
  case ioFailure

  public var errorDescription: String? {
    switch self {
    case .invalidFileURL:
      "The resident settings file URL is invalid."
    case .invalidMaximumBytes:
      "The resident settings file size limit is invalid."
    case .malformedSettings:
      "Resident settings are malformed or invalid."
    case .settingsTooLarge:
      "Resident settings exceed the allowed size."
    case .unsafeFile:
      "The resident settings path is not a private file owned by the current user."
    case .lockFailure:
      "The resident settings lock could not be acquired."
    case .encodingFailure:
      "Resident settings could not be encoded."
    case .ioFailure:
      "Resident settings could not be read or written."
    }
  }
}
