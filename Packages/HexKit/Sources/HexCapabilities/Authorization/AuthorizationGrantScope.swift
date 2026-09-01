public enum AuthorizationGrantScope: String, Codable, CaseIterable, Sendable {
  case once
  case run
  case session
  case persistent
}
