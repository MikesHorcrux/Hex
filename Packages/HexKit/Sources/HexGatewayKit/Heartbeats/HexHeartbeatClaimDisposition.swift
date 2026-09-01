public enum HexHeartbeatClaimDisposition: Equatable, Sendable {
  case claimed
  case alreadyClaimed
  case alreadyCompleted
  case schedulePaused
  case scheduleBusy
  case scheduleNotDue
  case scheduleMissing
}
