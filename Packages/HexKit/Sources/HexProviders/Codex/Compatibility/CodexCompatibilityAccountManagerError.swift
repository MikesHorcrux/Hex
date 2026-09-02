import Foundation

/// Secret-free failures from the user-triggered Codex compatibility account actions.
public enum CodexCompatibilityAccountManagerError: Error, Equatable, LocalizedError, Sendable {
  case loginTimedOut
  case loginRejected
  case loginNotFound
  case unsupported
  case failed

  public var errorDescription: String? {
    switch self {
    case .loginTimedOut:
      "Codex did not report a completed login within the allowed time."
    case .loginRejected:
      "Codex rejected the login."
    case .loginNotFound:
      "Codex could not find that login flow."
    case .unsupported:
      "Codex account actions are unavailable in this compatibility provider."
    case .failed:
      "The Codex account action failed."
    }
  }
}
