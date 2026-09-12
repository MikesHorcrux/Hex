import Foundation
import HexCore
import HexIPC

public enum HexGatewayHeartbeatRunnerError: Swift.Error, Equatable, LocalizedError, Sendable {
  case invalidConfiguration
  case timedOut

  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration:
      "The heartbeat runner configuration is invalid."
    case .timedOut:
      "The heartbeat run exceeded its bounded execution timeout."
    }
  }
}
