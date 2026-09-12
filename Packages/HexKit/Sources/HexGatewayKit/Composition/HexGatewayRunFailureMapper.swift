import HexIPC
import HexRuntime

/// Preserves actionable, already-redacted runtime failures at the gateway boundary instead of
/// collapsing every failed run into an indistinguishable driver error.
enum HexGatewayRunFailureMapper {
  static func map(_ error: AgentRuntimeError) -> GatewayFailure {
    let message = error.errorDescription ?? "The Hex agent runtime failed."
    let isRetryable: Bool
    switch error {
    case .providerFailure(_, let providerRetryable):
      isRetryable = providerRetryable
    case .duplicateRun, .invalidConfiguration, .invalidRequest, .modelUnavailable,
      .unsupportedCapability, .protocolViolation, .budgetExceeded, .authorizationFailure,
      .toolExecutionFailure, .journalFailure, .invalidState:
      isRetryable = false
    }
    return GatewayFailure(
      code: .runDriverFailed,
      message: message,
      isRetryable: isRetryable
    )
  }
}
