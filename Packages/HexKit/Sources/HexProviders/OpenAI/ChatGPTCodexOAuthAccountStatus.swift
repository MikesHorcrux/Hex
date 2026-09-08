/// Redacted state for the ChatGPT session owned by Hex.
public enum ChatGPTCodexOAuthAccountStatus: Equatable, Sendable {
  case signedOut
  case signedIn
  case unavailable

  public var title: String {
    switch self {
    case .signedOut:
      "Not signed in"
    case .signedIn:
      "Signed in with ChatGPT"
    case .unavailable:
      "Sign-in state unavailable"
    }
  }

  public var detail: String {
    switch self {
    case .signedOut:
      "Sign in to use your ChatGPT/Codex subscription for inference."
    case .signedIn:
      "Hex owns the agent loop; OpenAI supplies only model inference."
    case .unavailable:
      "Hex could not read the protected ChatGPT session from Keychain."
    }
  }
}
