import Darwin
import Synchronization
import Testing

@testable import HexMCP

@Suite("Bounded process cleanup ordering")
struct MCPBoundedProcessCleanupTests {
  @Test("A group exit race preserves successful cleanup after reaping proves the group is gone")
  func groupExitRaceIsVerifiedAfterReaping() throws {
    let script = CleanupScript()

    let status = try MCPBoundedProcessRunner.terminateAndReap(
      CleanupScript.processID,
      systemCalls: script.systemCalls
    )

    #expect(status == CleanupScript.waitStatus)
    #expect(script.events == ["group_kill", "observe_exit", "leader_kill", "reap", "group_probe"])
  }

  @Test("An already observed exit still requires a vanished process group")
  func previouslyObservedExitIsVerifiedAfterReaping() throws {
    let script = CleanupScript()

    let status = try MCPBoundedProcessRunner.terminateAndReap(
      CleanupScript.processID,
      leaderHasExited: true,
      systemCalls: script.systemCalls
    )

    #expect(status == CleanupScript.waitStatus)
    #expect(script.events == ["group_kill", "leader_kill", "reap", "group_probe"])
  }

  @Test(
    "A surviving or unverified group still fails after its leader is reaped",
    arguments: [Int32(0), EPERM])
  func survivingOrUnverifiedGroupFails(probeError: Int32) {
    let script = CleanupScript(groupProbeError: probeError)

    #expect(throws: MCPClientSessionError.connectionClosed) {
      try MCPBoundedProcessRunner.terminateAndReap(
        CleanupScript.processID,
        systemCalls: script.systemCalls
      )
    }

    #expect(script.events == ["group_kill", "observe_exit", "leader_kill", "reap", "group_probe"])
  }

  @Test("Losing child ownership during observation never signals or reaps that PID again")
  func lostOwnershipStopsCleanup() {
    let script = CleanupScript(observationError: ECHILD)

    #expect(throws: MCPClientSessionError.connectionClosed) {
      try MCPBoundedProcessRunner.terminateAndReap(
        CleanupScript.processID,
        systemCalls: script.systemCalls
      )
    }

    #expect(script.events == ["group_kill", "observe_exit"])
  }

  @Test("Failed reaping never retries signals or claims the process group disappeared")
  func failedReapingStopsCleanup() {
    let script = CleanupScript(waitError: ECHILD)

    #expect(throws: MCPClientSessionError.connectionClosed) {
      try MCPBoundedProcessRunner.terminateAndReap(
        CleanupScript.processID,
        systemCalls: script.systemCalls
      )
    }

    #expect(script.events == ["group_kill", "observe_exit", "leader_kill", "reap"])
  }

  @Test("A failed leader signal stays a cleanup failure even when the group later disappears")
  func deniedLeaderSignalFailsClosed() {
    let script = CleanupScript(leaderSignalError: EPERM)

    #expect(throws: MCPClientSessionError.connectionClosed) {
      try MCPBoundedProcessRunner.terminateAndReap(
        CleanupScript.processID,
        systemCalls: script.systemCalls
      )
    }

    #expect(script.events == ["group_kill", "observe_exit", "leader_kill", "reap", "group_probe"])
  }

  private final class CleanupScript: Sendable {
    // This PID is only consumed by injected closures; the fixture never invokes live syscalls.
    static let processID: pid_t = 12_345
    static let waitStatus: Int32 = 7 << 8

    private let recordedEvents = Mutex<[String]>([])
    private let groupProbeError: Int32
    private let observationError: Int32
    private let waitError: Int32
    private let leaderSignalError: Int32

    init(
      groupProbeError: Int32 = ESRCH,
      observationError: Int32 = 0,
      waitError: Int32 = 0,
      leaderSignalError: Int32 = 0
    ) {
      self.groupProbeError = groupProbeError
      self.observationError = observationError
      self.waitError = waitError
      self.leaderSignalError = leaderSignalError
    }

    var events: [String] { recordedEvents.withLock { $0 } }

    var systemCalls: MCPProcessCleanupSystemCalls {
      MCPProcessCleanupSystemCalls(
        sendSignal: { [self] processID, signal in
          #expect(processID == Self.processID || processID == -Self.processID)
          if signal == 0 {
            #expect(processID == -Self.processID)
            record("group_probe")
            return (groupProbeError == 0 ? 0 : -1, groupProbeError)
          }
          #expect(signal == SIGKILL)
          if processID == -Self.processID {
            record("group_kill")
            return (-1, EPERM)
          }
          record("leader_kill")
          return (leaderSignalError == 0 ? 0 : -1, leaderSignalError)
        },
        observeExit: { [self] processID in
          #expect(processID == Self.processID)
          record("observe_exit")
          return (observationError == 0 ? 0 : -1, observationError, 0, 0)
        },
        waitForLeader: { [self] processID in
          #expect(processID == Self.processID)
          record("reap")
          return (waitError == 0 ? processID : -1, waitError, Self.waitStatus)
        }
      )
    }

    private func record(_ event: String) {
      recordedEvents.withLock { $0.append(event) }
    }
  }
}
