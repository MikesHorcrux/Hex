import Foundation
import HexCore
import Synchronization

actor MCPManagedToolExecutorStartupRace {
  private var state = MCPManagedToolExecutorStartupRaceState.pending
  private var continuation: CheckedContinuation<MCPManagedToolExecutorStartupRaceOutcome, Never>?

  func waitForOutcome() async -> MCPManagedToolExecutorStartupRaceOutcome {
    switch state {
    case .resolved(let outcome):
      return outcome
    case .pending, .stopping:
      return await withCheckedContinuation { continuation in
        if case .resolved(let outcome) = state {
          continuation.resume(returning: outcome)
        } else {
          self.continuation = continuation
        }
      }
    }
  }

  func resolve(_ outcome: MCPManagedToolExecutorStartupRaceOutcome) {
    guard case .pending = state else { return }
    finish(outcome)
  }

  func stopAndResolve(
    _ outcome: MCPManagedToolExecutorStartupRaceOutcome,
    executor: MCPToolExecutor
  ) async {
    guard case .pending = state else { return }
    state = .stopping(outcome)
    await executor.requestStop()
    finish(outcome)
  }

  private func finish(_ outcome: MCPManagedToolExecutorStartupRaceOutcome) {
    state = .resolved(outcome)
    let continuation = self.continuation
    self.continuation = nil
    continuation?.resume(returning: outcome)
  }
}
