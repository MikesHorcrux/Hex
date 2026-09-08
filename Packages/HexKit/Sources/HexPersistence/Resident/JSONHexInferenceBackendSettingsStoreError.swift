import Foundation

/// Secret-free failures from the inference-backend settings store.
public enum JSONHexInferenceBackendSettingsStoreError: Error, Equatable, LocalizedError, Sendable {
  case invalidFileURL
  case invalidMaximumBytes
  case malformedSettings
  case encodingFailure
  case settingsTooLarge
  case unsafeFile
  case ioFailure
  case lockFailure

  public var errorDescription: String? {
    switch self {
    case .invalidFileURL:
      "The inference-backend settings file location is invalid."
    case .invalidMaximumBytes:
      "The inference-backend settings size limit is invalid."
    case .malformedSettings:
      "The inference-backend settings file is malformed."
    case .encodingFailure:
      "The inference-backend settings could not be encoded."
    case .settingsTooLarge:
      "The inference-backend settings exceed their size limit."
    case .unsafeFile:
      "The inference-backend settings file is not safe to use."
    case .ioFailure:
      "The inference-backend settings could not be read or written."
    case .lockFailure:
      "The inference-backend settings are busy or could not be locked."
    }
  }
}
