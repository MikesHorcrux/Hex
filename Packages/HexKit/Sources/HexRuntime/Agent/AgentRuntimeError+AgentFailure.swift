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
    case .providerFailure(_, let providerRetryable):
      AgentFailure(
        code: .provider,
        message: errorDescription ?? "Inference provider failure.",
        isRetryable: isRetryable && providerRetryable
      )
    case .protocolViolation:
      AgentFailure(code: .provider, message: errorDescription ?? "Inference provider failure.")
    case .authorizationFailure:
      AgentFailure(code: .authorization, message: errorDescription ?? "Authorization failure.")
    case .toolExecutionFailure:
      AgentFailure(code: .toolExecution, message: errorDescription ?? "Tool execution failure.")
    case .journalFailure:
      AgentFailure(code: .journal, message: errorDescription ?? "Event journal failure.")
    }
  }

  func constrainingRetryability(to isRetryable: Bool) -> AgentRuntimeError {
    guard case .providerFailure(let message, let providerRetryable) = self else {
      return self
    }
    return .providerFailure(message, isRetryable: isRetryable && providerRetryable)
  }
}
