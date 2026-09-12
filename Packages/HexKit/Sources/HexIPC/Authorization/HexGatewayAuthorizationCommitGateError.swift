import Foundation
import Synchronization

public enum HexGatewayAuthorizationCommitGateError: Error, Equatable, LocalizedError, Sendable {
  case closed

  public var errorDescription: String? {
    switch self {
    case .closed:
      "The authorization connection is no longer valid."
    }
  }
}
