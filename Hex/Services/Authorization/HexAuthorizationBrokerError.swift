import Foundation
import HexCapabilities
import HexCore

enum HexAuthorizationBrokerError: Error, Equatable, LocalizedError, Sendable {
  case requestNotPending
  case requestAlreadyPending

  var errorDescription: String? {
    switch self {
    case .requestNotPending:
      "That authorization request is no longer pending. Reconnect and try again."
    case .requestAlreadyPending:
      "That authorization request is already pending. Answer the existing request first."
    }
  }
}
