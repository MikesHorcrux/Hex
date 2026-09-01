import HexProviders

/// In-memory developer credential seam. The value is never persisted, described, or logged.
struct HexOpenAICredentialProvider: OpenAICredentialProvider, Sendable {
  private let value: String

  init(apiKey: String) {
    value = apiKey
  }

  func apiKey() async throws -> String {
    try Task.checkCancellation()
    return value
  }
}
