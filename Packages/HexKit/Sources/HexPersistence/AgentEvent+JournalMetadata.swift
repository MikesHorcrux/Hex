import HexCore

extension AgentEvent {
  var journalKind: String {
    switch self {
    case .runStarted:
      "run_started"
    case .messageAppended:
      "message_appended"
    case .inferenceRequested:
      "inference_requested"
    case .inferenceEvent:
      "inference_event"
    case .authorizationRequested:
      "authorization_requested"
    case .authorizationDecided:
      "authorization_decided"
    case .toolStarted:
      "tool_started"
    case .toolFinished:
      "tool_finished"
    case .runCompleted:
      "run_completed"
    case .runCancelled:
      "run_cancelled"
    case .runFailed:
      "run_failed"
    }
  }

  var journalToolCallID: ToolCallID? {
    switch self {
    case .toolStarted(let call):
      call.id
    case .toolFinished(let result):
      result.toolCallID
    default:
      nil
    }
  }

  var startsRun: Bool {
    if case .runStarted = self {
      return true
    }
    return false
  }

  var terminatesRun: Bool {
    switch self {
    case .runCompleted, .runCancelled, .runFailed:
      true
    default:
      false
    }
  }
}
