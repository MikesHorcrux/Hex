import Foundation

/// User-facing challenge returned by a Codex-managed ChatGPT login flow.
public enum CodexLoginChallenge: Equatable, Sendable {
  case browser(loginID: CodexLoginID, authorizationURL: URL)
  case deviceCode(loginID: CodexLoginID, userCode: String, verificationURL: URL)

  public var loginID: CodexLoginID {
    switch self {
    case .browser(let loginID, _), .deviceCode(let loginID, _, _):
      loginID
    }
  }
}
