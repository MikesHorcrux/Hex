import Foundation
import HexCapabilities
import HexCore
import HexIPC

public enum HexGatewayAuthorizationBrokerError:
  Swift.Error,
  Equatable,
  LocalizedError,
  Sendable,
  HexGatewayAuthorizationDecisionFailure
{
  case requestNotPending
  case requestMismatch
  case requestAlreadyPending

  public var errorDescription: String? {
    switch self {
    case .requestNotPending:
      "That authorization request is no longer pending."
    case .requestMismatch:
      "The authorization response did not match the pending request."
    case .requestAlreadyPending:
      "That authorization request is already pending."
    }
  }

  public var gatewayFailure: GatewayFailure {
    switch self {
    case .requestNotPending:
      GatewayFailure(
        code: .authorizationRequestNotPending,
        message: "The authorization request is no longer pending."
      )
    case .requestMismatch:
      GatewayFailure(
        code: .authorizationRequestMismatch,
        message: "The authorization response did not match the pending request."
      )
    case .requestAlreadyPending:
      GatewayFailure(
        code: .authorizationRequestAlreadyPending,
        message: "The authorization request is already pending."
      )
    }
  }
}
