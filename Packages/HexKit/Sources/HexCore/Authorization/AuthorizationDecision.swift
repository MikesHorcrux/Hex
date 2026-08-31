public enum AuthorizationDecision: Codable, Equatable, Sendable {
  case allow
  case deny(reason: String?)
}
