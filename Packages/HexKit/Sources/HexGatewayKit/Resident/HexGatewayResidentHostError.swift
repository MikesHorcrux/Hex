import Darwin
import Dispatch
@preconcurrency import Foundation
import HexCapabilities
import HexCore
import HexIPC
import HexMCP
import HexPersistence
import HexPersonality
import HexProviders

public enum HexGatewayResidentHostError: Swift.Error, Equatable, LocalizedError, Sendable {
  case alreadyRunning

  public var errorDescription: String? {
    switch self {
    case .alreadyRunning:
      "The resident gateway is already running."
    }
  }
}
