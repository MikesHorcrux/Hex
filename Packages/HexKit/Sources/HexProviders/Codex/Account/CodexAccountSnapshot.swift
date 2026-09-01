/// Current account state reported by Codex app-server.
public struct CodexAccountSnapshot: Equatable, Sendable {
  public let account: CodexAccount?
  public let requiresOpenAIAuthentication: Bool
}
