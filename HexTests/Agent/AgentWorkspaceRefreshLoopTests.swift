import Foundation
import Testing

@testable import Hex

@MainActor
@Suite("Workspace refresh lifetime")
struct AgentWorkspaceRefreshLoopTests {
  @Test func cancellationDuringRefreshSkipsTheNextWait() async {
    var refreshes = 0
    var waits = 0
    let task = Task { @MainActor in
      await AgentWorkspaceRefreshLoop(wait: { waits += 1 }).run {
        refreshes += 1
        withUnsafeCurrentTask { $0?.cancel() }
      }
    }
    await task.value
    #expect(refreshes == 1)
    #expect(waits == 0)
  }

  @Test func anAlreadyCancelledTaskDoesNotRefresh() async {
    var refreshes = 0
    let task = Task { @MainActor in
      withUnsafeCurrentTask { $0?.cancel() }
      await AgentWorkspaceRefreshLoop().run { refreshes += 1 }
    }
    await task.value
    #expect(refreshes == 0)
  }

  @Test func aFailedRefreshStopsPolling() async {
    var refreshes = 0
    var waits = 0
    await AgentWorkspaceRefreshLoop(wait: { waits += 1 }).run {
      refreshes += 1
      throw CancellationError()
    }
    #expect(refreshes == 1)
    #expect(waits == 0)
  }

  @Test func cancellationWhileWaitingStopsPolling() async {
    var refreshes = 0
    var waits = 0
    await AgentWorkspaceRefreshLoop(wait: {
      waits += 1
      throw CancellationError()
    }).run { refreshes += 1 }
    #expect(refreshes == 1)
    #expect(waits == 1)
  }
}
