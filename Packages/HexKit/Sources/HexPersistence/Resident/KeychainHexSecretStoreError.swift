import Foundation

/// Safe failures from the resident Keychain adapter. Secret values are never included.
public enum KeychainHexSecretStoreError: Error, Equatable, LocalizedError, Sendable {
  case invalidSecret
  case missingSecret
  case invalidStoredSecret
  case keychainFailure(Int32)

  public var errorDescription: String? {
    switch self {
    case .invalidSecret:
      "The resident secret is invalid."
    case .missingSecret:
      "The requested resident secret is not configured."
    case .invalidStoredSecret:
      "The resident secret store contains an invalid value."
    case .keychainFailure:
      "The resident secret store is unavailable."
    }
  }
}
