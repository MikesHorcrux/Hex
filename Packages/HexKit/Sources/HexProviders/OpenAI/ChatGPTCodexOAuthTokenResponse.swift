/// Validated shape returned by an OAuth token exchange or refresh.
public struct ChatGPTCodexOAuthTokenResponse: Equatable, Sendable {
  public let accessToken: String
  public let refreshToken: String?
  public let idToken: String?
  public let expiresIn: Int?

  public init(
    accessToken: String,
    refreshToken: String?,
    idToken: String?,
    expiresIn: Int?
  ) {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.idToken = idToken
    self.expiresIn = expiresIn
  }
}
