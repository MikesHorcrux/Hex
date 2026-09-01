enum OpenAIResponseLifecycle: Sendable {
  case awaitingStart
  case createdQueued
  case createdInProgress
  case queued
  case inProgress
  case output
  case terminal

  var isStreaming: Bool {
    switch self {
    case .createdQueued, .createdInProgress, .queued, .inProgress, .output:
      true
    case .awaitingStart, .terminal:
      false
    }
  }
}
