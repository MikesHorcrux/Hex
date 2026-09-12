import Foundation
import HexCore
import Synchronization

enum MCPManagedToolExecutorStartupRaceState {
  case pending
  case stopping(MCPManagedToolExecutorStartupRaceOutcome)
  case resolved(MCPManagedToolExecutorStartupRaceOutcome)
}
