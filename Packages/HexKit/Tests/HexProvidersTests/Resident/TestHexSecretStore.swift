import HexCore

@testable import HexProviders

actor TestHexSecretStore: HexSecretStore {
  private var storedValue: String?

  init(value: String?) {
    storedValue = value
  }

  func secret(for key: HexSecretKey) async throws -> String {
    guard key == .openAIAPIKey, let storedValue else {
      throw TestHexSecretStoreError.missing
    }
    return storedValue
  }

  func exists(_ key: HexSecretKey) async throws -> Bool {
    key == .openAIAPIKey && storedValue != nil
  }

  func save(_ secret: String, for key: HexSecretKey) async throws {
    guard key == .openAIAPIKey else {
      throw TestHexSecretStoreError.missing
    }
    storedValue = secret
  }

  func delete(_ key: HexSecretKey) async throws {
    guard key == .openAIAPIKey else {
      throw TestHexSecretStoreError.missing
    }
    storedValue = nil
  }
}
