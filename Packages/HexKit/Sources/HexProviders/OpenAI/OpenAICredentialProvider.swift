/// Supplies an OpenAI Platform API key at request time.
///
/// Implementations should read from a secret store and must not expose the key through descriptions,
/// logging, or thrown error text. This boundary does not support ChatGPT subscription credentials.
public protocol OpenAICredentialProvider: Sendable {
  func apiKey() async throws -> String
}
