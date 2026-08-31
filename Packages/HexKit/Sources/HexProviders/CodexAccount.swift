/// Non-secret account metadata reported by Codex app-server.
public enum CodexAccount: Equatable, Sendable {
  case apiKey
  case chatGPT(email: String?, plan: CodexAccountPlan)
  case amazonBedrock(usesCodexManagedCredentials: Bool)
}
