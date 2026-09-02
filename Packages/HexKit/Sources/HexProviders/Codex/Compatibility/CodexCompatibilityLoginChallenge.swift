import Foundation

/// A secret-free presentation model for one Codex-managed ChatGPT login challenge.
///
/// The challenge contains only the browser/device-code information that Codex deliberately
/// returns for user interaction. Login completions and credentials remain inside the account
/// manager and are never represented by this type.
public enum CodexCompatibilityLoginChallenge: Equatable, Sendable {
  case browser(loginID: CodexLoginID, authorizationURL: URL)
  case deviceCode(loginID: CodexLoginID, userCode: String, verificationURL: URL)

  public var loginID: CodexLoginID {
    switch self {
    case .browser(let loginID, _), .deviceCode(let loginID, _, _):
      loginID
    }
  }

  public init(_ challenge: CodexLoginChallenge) {
    switch challenge {
    case .browser(let loginID, let authorizationURL):
      self = .browser(loginID: loginID, authorizationURL: authorizationURL)
    case .deviceCode(let loginID, let userCode, let verificationURL):
      self = .deviceCode(
        loginID: loginID,
        userCode: userCode,
        verificationURL: verificationURL
      )
    }
  }
}
