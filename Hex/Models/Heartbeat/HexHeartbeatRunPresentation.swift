import HexIPC

nonisolated enum HexHeartbeatRunPresentation {
  static func status(_ run: GatewayHeartbeatRun) -> String {
    guard let outcome = run.outcome else { return "Outcome not recorded" }
    switch outcome.kind {
    case .succeeded: return "Succeeded"
    case .failed: return "Failed"
    case .cancelled: return "Cancelled"
    case .skipped: return "Skipped"
    case .interrupted: return "Interrupted"
    }
  }

  static func symbol(_ run: GatewayHeartbeatRun) -> String {
    guard let outcome = run.outcome else { return "questionmark.circle" }
    switch outcome.kind {
    case .succeeded: return "checkmark.circle"
    case .failed: return "exclamationmark.circle"
    case .cancelled, .interrupted: return "stop.circle"
    case .skipped: return "forward.end"
    }
  }
}
