import Foundation

/// Public, secret-free failures from the Codex account bridge.
public enum CodexAccountClientError: Error, Equatable, LocalizedError, Sendable {
  case transitionInProgress
  case loginAlreadyPending
  case noPendingLogin
  case loginIdentifierMismatch
  case unexpectedLoginCompletion
  case malformedResponse
  case transportFailure

  public var errorDescription: String? {
    switch self {
    case .transitionInProgress:
      "A Codex account transition is already in progress."
    case .loginAlreadyPending:
      "A Codex login is already pending."
    case .noPendingLogin:
      "No Codex login is pending."
    case .loginIdentifierMismatch:
      "The Codex login identifier did not match the pending login."
    case .unexpectedLoginCompletion:
      "Codex reported a login completion without a matching pending login."
    case .malformedResponse:
      "Codex returned an invalid account response."
    case .transportFailure:
      "The Codex account request failed."
    }
  }
}
