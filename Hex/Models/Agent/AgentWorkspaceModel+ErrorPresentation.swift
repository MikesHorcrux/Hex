import Foundation
import HexIPC

extension AgentWorkspaceModel {
  func actionableMessage(for error: any Error, context: String) -> String {
    if let failure = error as? GatewayFailure {
      let remedy =
        failure.isRetryable
        ? "Try reconnecting, then retry the run."
        : "Check the gateway configuration and try again."
      return "\(context): \(failure.message) \(remedy)"
    }
    return "\(context): \(error.localizedDescription). Check the gateway and try again."
  }
}
