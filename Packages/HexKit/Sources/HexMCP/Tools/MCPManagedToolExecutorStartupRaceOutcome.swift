import Foundation
import HexCore
import Synchronization

enum MCPManagedToolExecutorStartupRaceOutcome: Sendable {
  case started(availableToolCount: Int)
  case failed(MCPManagedToolFailure)
  case timedOut
  case cancelled
}
