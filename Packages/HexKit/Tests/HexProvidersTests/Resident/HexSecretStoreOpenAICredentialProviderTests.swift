import HexCore
import Testing

@testable import HexProviders

@Suite("Resident OpenAI credential adapter")
struct HexSecretStoreOpenAICredentialProviderTests {
  @Test
  func readsOpenAIKeyOnlyThroughSecretStore() async throws {
    let store = TestHexSecretStore(value: "sk-test-secret")
    let provider = HexSecretStoreOpenAICredentialProvider(store: store)

    #expect(try await provider.apiKey() == "sk-test-secret")
    #expect(try await store.exists(.openAIAPIKey))
  }
}
