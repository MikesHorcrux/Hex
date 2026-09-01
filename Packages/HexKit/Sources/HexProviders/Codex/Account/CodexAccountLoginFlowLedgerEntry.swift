enum CodexAccountLoginFlowLedgerEntry: Equatable, Sendable {
  case pending
  case retiredAwaitingCompletion
  case completionAccepted
}
