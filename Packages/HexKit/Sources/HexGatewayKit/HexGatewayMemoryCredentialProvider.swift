import HexProviders

/// In-memory OpenAI credential seam for the resident composition root. The key is never persisted,
/// interpolated into a process environment, or included in a description or diagnostic value.
public struct HexGatewayMemoryCredentialProvider: OpenAICredentialProvider, Sendable {
  private let value: String

  public init(apiKey: String) {
    value = apiKey
  }

  public func apiKey() async throws -> String {
    try Task.checkCancellation()
    return value
  }
}
