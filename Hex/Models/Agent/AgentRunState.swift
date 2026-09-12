enum AgentRunState: String, Sendable {
  case idle
  case starting
  case running
  case waitingForAuthorization
  case cancelling
  case completed
  case cancelled
  case failed

  var label: String {
    switch self {
    case .idle:
      "Ready"
    case .starting:
      "Starting"
    case .running:
      "Running"
    case .waitingForAuthorization:
      "Waiting for approval"
    case .cancelling:
      "Stopping"
    case .completed:
      "Completed"
    case .cancelled:
      "Cancelled"
    case .failed:
      "Failed"
    }
  }

  var isTerminal: Bool {
    switch self {
    case .completed, .cancelled, .failed:
      true
    case .idle, .starting, .running, .waitingForAuthorization, .cancelling:
      false
    }
  }
}
