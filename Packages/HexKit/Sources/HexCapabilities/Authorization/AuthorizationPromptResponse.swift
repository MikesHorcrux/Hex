public enum AuthorizationPromptResponse: Codable, Equatable, Sendable {
  case allow(scope: AuthorizationGrantScope)
  case deny(reason: String?)
}
