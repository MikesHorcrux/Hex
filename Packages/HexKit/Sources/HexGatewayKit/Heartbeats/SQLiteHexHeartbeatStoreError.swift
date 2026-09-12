import Foundation

public enum SQLiteHexHeartbeatStoreError: Error, Equatable, LocalizedError, Sendable {
  case unavailable
  case corrupt
  case unsupportedSchema
  case invalidCursor
  case payloadTooLarge
  case commitOutcomeUncertain

  public var errorDescription: String? {
    switch self {
    case .unavailable: "The scheduled-work history store is unavailable. No history was discarded."
    case .corrupt: "The scheduled-work history contains invalid data. It was not replaced."
    case .unsupportedSchema: "This scheduled-work history requires a compatible version of Hex."
    case .invalidCursor:
      "The scheduled-work history cursor no longer identifies this store or query."
    case .payloadTooLarge:
      "The scheduled-work metadata exceeds its safe payload limit. No history was discarded."
    case .commitOutcomeUncertain:
      "The scheduled-work write outcome is uncertain. Reload before retrying."
    }
  }
}
