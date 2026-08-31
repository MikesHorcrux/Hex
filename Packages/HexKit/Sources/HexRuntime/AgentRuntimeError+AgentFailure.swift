import HexCore

extension AgentRuntimeError {
  func agentFailure(isRetryable: Bool = true) -> AgentFailure {
    switch self {
    case .duplicateRun, .invalidRequest, .modelUnavailable:
      AgentFailure(code: .invalidRequest, message: errorDescription ?? "Invalid run request.")
    case .invalidConfiguration, .invalidState, .budgetExceeded:
      AgentFailure(code: .invalidState, message: errorDescription ?? "Invalid runtime state.")
    case .unsupportedCapability:
      AgentFailure(
        code: .unsupportedCapability,
        message: errorDescription ?? "Unsupported capability."
      )
    case .providerFailure, .protocolViolation:
      AgentFailure(
        code: .provider,
        message: errorDescription ?? "Inference provider failure.",
        isRetryable: isRetryable
      )
    case .authorizationFailure:
      AgentFailure(code: .authorization, message: errorDescription ?? "Authorization failure.")
    case .toolExecutionFailure:
      AgentFailure(code: .toolExecution, message: errorDescription ?? "Tool execution failure.")
    case .journalFailure:
      AgentFailure(code: .journal, message: errorDescription ?? "Event journal failure.")
    }
  }
}
