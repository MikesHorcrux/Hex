import Foundation

/// Validation failures for persisted resident runtime settings.
public enum HexResidentRuntimeSettingsError: Error, Equatable, LocalizedError, Sendable {
  case invalidModelID
  case invalidWorkspaceRoot
  case unsupportedSchemaVersion(Int)

  public var errorDescription: String? {
    switch self {
    case .invalidModelID:
      "The resident runtime model identifier is invalid."
    case .invalidWorkspaceRoot:
      "The resident runtime workspace must be an absolute file URL."
    case .unsupportedSchemaVersion:
      "The resident runtime settings use an unsupported schema version."
    }
  }
}
