/// Request-time authorization for one OpenAI Responses-compatible service.
///
/// Values are deliberately short-lived and must never be logged or persisted outside a secret
/// store. `accountID` is required only by the ChatGPT Codex subscription endpoint.
public struct OpenAIResponsesAuthorization: Sendable {
  public let bearerToken: String
  public let accountID: String?

  public init(bearerToken: String, accountID: String? = nil) {
    self.bearerToken = bearerToken
    self.accountID = accountID
  }
}
