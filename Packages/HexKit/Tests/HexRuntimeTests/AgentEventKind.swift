enum AgentEventKind: Equatable {
  case runStarted
  case messageAppended
  case inferenceRequested
  case inferenceStarted
  case textDelta
  case reasoningSummary
  case toolCall
  case usage
  case inferenceCompleted
  case authorizationRequested
  case authorizationDecided
  case toolStarted
  case toolFinished
  case runCompleted
  case runCancelled
  case runFailed
}
