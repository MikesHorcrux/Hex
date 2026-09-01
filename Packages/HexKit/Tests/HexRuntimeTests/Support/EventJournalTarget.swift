enum EventJournalTarget: Sendable {
  case runStarted
  case runCompleted
  case toolStarted
  case toolFinished
  case inferenceEvent
  case authorizationRequested
  case runCancelled
  case runFailed
  case appendNumber(Int)
}
