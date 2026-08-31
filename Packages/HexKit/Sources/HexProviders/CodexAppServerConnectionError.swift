import Foundation

/// Secret-free failures from the app-server wire connection.
public enum CodexAppServerConnectionError: Error, Equatable, LocalizedError, Sendable {
  case invalidConfiguration
  case alreadyConnected
  case connectionClosed
  case handshakeFailed
  case protocolViolation
  case limitExceeded
  case requestTimedOut
  case remoteError(code: Int64)
  case transportFailure

  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration:
      "The Codex connection configuration is invalid."
    case .alreadyConnected:
      "The Codex connection is already open."
    case .connectionClosed:
      "The Codex connection is closed."
    case .handshakeFailed:
      "The Codex connection handshake failed."
    case .protocolViolation:
      "Codex sent an invalid protocol message."
    case .limitExceeded:
      "A Codex connection limit was exceeded."
    case .requestTimedOut:
      "The Codex request timed out."
    case .remoteError(let code):
      "Codex rejected the request with error code \(code)."
    case .transportFailure:
      "The Codex transport failed."
    }
  }
}
