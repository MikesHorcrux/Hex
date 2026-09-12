import Foundation
import HexCore

struct HexHeartbeatSchedulerExecution: Sendable {
  let outcome: HexHeartbeatOutcome
  let wasCancelled: Bool
}
