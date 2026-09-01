@testable import HexProviders

struct TestOpenAICredentialProvider: OpenAICredentialProvider {
  let key: String

  func apiKey() async throws -> String {
    key
  }
}
