import Foundation

/// Redacted failures for Hex-owned ChatGPT/Codex authorization.
public enum ChatGPTCodexOAuthError: Error, Equatable, LocalizedError, Sendable {
  case missingCredentials
  case invalidCredentials
  case authorizationTimedOut
  case authorizationRejected
  case rateLimited
  case tokenExchangeFailed
  case refreshRejected
  case unexpectedResponse
  case transportFailed

  public var errorDescription: String? {
    switch self {
    case .missingCredentials:
      "Hex is not signed in with ChatGPT."
    case .invalidCredentials:
      "The saved ChatGPT session is invalid. Sign in again."
    case .authorizationTimedOut:
      "ChatGPT sign-in timed out. Start sign-in again."
    case .authorizationRejected:
      "ChatGPT did not approve this sign-in. Start again."
    case .rateLimited:
      "OpenAI is temporarily rate-limiting sign-in. Wait and try again."
    case .tokenExchangeFailed:
      "ChatGPT sign-in could not complete. Start sign-in again."
    case .refreshRejected:
      "The ChatGPT session expired or was replaced. Sign in again."
    case .unexpectedResponse:
      "OpenAI's sign-in service returned a response Hex could not understand. Update Hex and try again."
    case .transportFailed:
      "Hex could not reach OpenAI's sign-in service."
    }
  }
}
