import HexCore

/// Adapts the generic resident secret store to the OpenAI provider boundary.
public struct HexSecretStoreOpenAICredentialProvider: OpenAICredentialProvider, Sendable {
  private let store: any HexSecretStore

  public init(store: any HexSecretStore) {
    self.store = store
  }

  public func apiKey() async throws -> String {
    try await store.secret(for: .openAIAPIKey)
  }
}
