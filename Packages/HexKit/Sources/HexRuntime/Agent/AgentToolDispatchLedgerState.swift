import HexCore

enum AgentToolDispatchLedgerState: Equatable, Sendable {
  case neverStarted
  case startAttempted
  case receiptAttempted
  case settled
}
