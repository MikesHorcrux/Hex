import Foundation

public enum HexResidentDataPathsPathError: Error, Equatable, LocalizedError, Sendable {
  case invalidApplicationSupportURL
  case invalidDataURL
  case applicationSupportUnavailable

  public var errorDescription: String? {
    switch self {
    case .invalidApplicationSupportURL:
      "Hex could not use the configured Application Support directory."
    case .invalidDataURL:
      "Hex resident data paths must be absolute file URLs."
    case .applicationSupportUnavailable:
      "Hex could not locate Application Support for the resident gateway."
    }
  }
}
