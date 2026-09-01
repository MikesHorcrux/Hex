/// Supported Codex-managed ChatGPT login flows.
public enum CodexChatGPTLoginMode: Equatable, Sendable {
  case browser
  case deviceCode
}
