extension OpenAICredentialProvider {
  public func authorization() async throws -> OpenAIResponsesAuthorization {
    OpenAIResponsesAuthorization(bearerToken: try await apiKey())
  }
}
