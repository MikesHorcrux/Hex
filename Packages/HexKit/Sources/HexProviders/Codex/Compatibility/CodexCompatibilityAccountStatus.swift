/// Honest account and availability state for the Codex compatibility backend.
///
/// The `.signedIn` case means that Codex reported an account through app-server; it does not mean
/// Hex received a reusable API key. The compatibility backend is an account/runtime integration,
/// not a raw OpenAI Responses API credential source.
public enum CodexCompatibilityAccountStatus: Equatable, Sendable {
  case notConfigured
  case checking
  case unavailable
  case signedOut
  case requiresOpenAIAuthentication
  case signedIn(account: CodexAccount)

  public var title: String {
    switch self {
    case .notConfigured:
      "Not configured"
    case .checking:
      "Checking Codex account"
    case .unavailable:
      "Codex unavailable"
    case .signedOut:
      "Signed out"
    case .requiresOpenAIAuthentication:
      "OpenAI authentication required"
    case .signedIn:
      "Codex account available"
    }
  }

  public var detail: String {
    switch self {
    case .notConfigured:
      "Choose an existing Codex executable to enable compatibility mode."
    case .checking:
      "Hex is asking the Codex app-server for its redacted account state."
    case .unavailable:
      "Hex could not read the Codex app-server account state."
    case .signedOut:
      "Sign in through Codex to use compatibility mode."
    case .requiresOpenAIAuthentication:
      "Codex reports that OpenAI authentication is required."
    case .signedIn:
      "Codex owns the account credentials; Hex does not receive them."
    }
  }

  public init(snapshot: CodexAccountSnapshot) {
    if snapshot.requiresOpenAIAuthentication {
      self = .requiresOpenAIAuthentication
    } else if let account = snapshot.account {
      self = .signedIn(account: account)
    } else {
      self = .signedOut
    }
  }
}
