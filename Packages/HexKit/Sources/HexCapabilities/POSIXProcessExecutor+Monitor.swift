import Darwin
import Foundation

extension POSIXProcessExecutor {
  func monitor(
    _ process: SpawnedProcess,
    timeoutSeconds: Int,
    startedAt: UInt64
  ) async throws -> ProcessExecutionResult {
    var output = Data()
    var leaderHasExited = false
    var leaderMayHaveBeenReaped = false
    var cleanupAttempted = false
    let timeoutNanoseconds = UInt64(timeoutSeconds) * 1_000_000_000
    let (deadline, deadlineOverflowed) = startedAt.addingReportingOverflow(timeoutNanoseconds)

    defer { Darwin.close(process.outputDescriptor) }
    guard !deadlineOverflowed else {
      cleanupAttempted = true
      _ = try terminateAndReap(process.processID)
      throw ProcessExecutionError.invalidRequest
    }

    do {
      while true {
        try Task.checkCancellation()
        let drainResult = try drain(
          process.outputDescriptor,
          into: &output,
          maximumBytes: configuration.maximumOutputBytes
        )
        let reachedEndOfFile = drainResult.reachedEndOfFile
        if drainResult.exceededLimit {
          cleanupAttempted = true
          _ = try terminateAndReap(
            process.processID,
            leaderHasExited: leaderHasExited
          )
          return ProcessExecutionResult(
            termination: .outputLimitExceeded,
            output: output,
            durationMilliseconds: elapsedMilliseconds(since: startedAt)
          )
        }

        if !leaderHasExited {
          leaderHasExited = try observeExit(
            process.processID,
            leaderMayHaveBeenReaped: &leaderMayHaveBeenReaped
          )
        }

        if leaderHasExited && reachedEndOfFile {
          cleanupAttempted = true
          let status = try terminateAndReap(
            process.processID,
            leaderHasExited: true
          )
          return ProcessExecutionResult(
            termination: termination(from: status),
            output: output,
            durationMilliseconds: elapsedMilliseconds(since: startedAt)
          )
        }

        if DispatchTime.now().uptimeNanoseconds >= deadline {
          cleanupAttempted = true
          _ = try terminateAndReap(
            process.processID,
            leaderHasExited: leaderHasExited
          )
          return ProcessExecutionResult(
            termination: .timedOut,
            output: output,
            durationMilliseconds: elapsedMilliseconds(since: startedAt)
          )
        }
        try await Task.sleep(
          for: .milliseconds(configuration.pollingIntervalMilliseconds)
        )
      }
    } catch is CancellationError {
      if !cleanupAttempted {
        cleanupAttempted = true
        guard !leaderMayHaveBeenReaped else {
          throw ProcessExecutionError.cleanupFailed
        }
        _ = try terminateAndReap(
          process.processID,
          leaderHasExited: leaderHasExited
        )
      }
      throw CancellationError()
    } catch {
      if !cleanupAttempted {
        cleanupAttempted = true
        guard !leaderMayHaveBeenReaped else {
          throw ProcessExecutionError.cleanupFailed
        }
        do {
          _ = try terminateAndReap(
            process.processID,
            leaderHasExited: leaderHasExited
          )
        } catch let cleanupError {
          throw cleanupError
        }
      }
      throw error
    }
  }

  /// Observes an exited leader without reaping it. Keeping the waitable child alive until the
  /// process group has been signaled prevents a later negative `kill` from targeting a recycled
  /// process-group identifier.
  private func observeExit(
    _ processID: pid_t,
    leaderMayHaveBeenReaped: inout Bool
  ) throws -> Bool {
    var information = siginfo_t()
    let waitResult = waitid(
      P_PID,
      id_t(processID),
      &information,
      WEXITED | WNOHANG | WNOWAIT
    )
    guard waitResult == 0 else {
      if errno == EINTR {
        return false
      }
      if errno == ECHILD {
        leaderMayHaveBeenReaped = true
      }
      throw ProcessExecutionError.ioFailure
    }
    return information.si_pid == processID
  }

  /// Signals the owned group before reaping the leader, then waits for that leader. The group
  /// signal is also performed for ordinary completion so descendants that detached their output
  /// cannot outlive a successful result. `setsid`/`setpgid` called by the child can escape this
  /// group; this accepted residual requires a Darwin primitive beyond `posix_spawn` to contain.
  func terminateAndReap(
    _ processID: pid_t,
    leaderHasExited: Bool = false
  ) throws -> Int32 {
    guard processID > 0 else {
      throw ProcessExecutionError.cleanupFailed
    }

    var cleanupFailed = false
    let groupSignalResult = Darwin.kill(-processID, SIGKILL)
    let groupSignalError = groupSignalResult == 0 ? 0 : errno
    // Darwin excludes zombie members from POSIX process-group signalling. When WNOWAIT has
    // already observed this owned leader's exit, a zombie-only group can therefore report EPERM
    // even though there is no live descendant left to terminate. Keep that result provisional:
    // the leader remains waitable while it is signalled and reaped, then the old group is probed
    // without a signal. This preserves the PID/PGID reuse guard and does not hide a live group.
    let groupSignalPermissionDenied =
      leaderHasExited && groupSignalResult < 0 && groupSignalError == EPERM
    if groupSignalResult < 0,
      groupSignalError != ESRCH,
      !groupSignalPermissionDenied
    {
      cleanupFailed = true
    }

    if !leaderHasExited || groupSignalPermissionDenied {
      let leaderSignalResult = Darwin.kill(processID, SIGKILL)
      let leaderSignalError = leaderSignalResult == 0 ? 0 : errno
      if leaderSignalResult < 0, leaderSignalError != ESRCH {
        cleanupFailed = true
      }
    }

    var status = Int32(0)
    var didReap = false
    while true {
      let waitResult = waitpid(processID, &status, 0)
      if waitResult == processID {
        didReap = true
        break
      }
      if waitResult < 0, errno == EINTR {
        continue
      }
      cleanupFailed = true
      break
    }

    if didReap, groupSignalPermissionDenied {
      // The leader PID is no longer protected after waitpid succeeds, so this must remain a
      // non-signaling probe. ESRCH proves the EPERM came from the old, zombie-only group; 0,
      // EPERM, or any other error means cleanup cannot prove that group is gone.
      let groupProbeResult = Darwin.kill(-processID, 0)
      let groupProbeError = groupProbeResult == 0 ? 0 : errno
      let oldGroupIsGone = groupProbeResult < 0 && groupProbeError == ESRCH
      if !oldGroupIsGone {
        cleanupFailed = true
      }
    }

    guard didReap, !cleanupFailed else {
      throw ProcessExecutionError.cleanupFailed
    }
    return status
  }

  private func drain(
    _ descriptor: Int32,
    into output: inout Data,
    maximumBytes: Int
  ) throws -> (reachedEndOfFile: Bool, exceededLimit: Bool) {
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      try Task.checkCancellation()
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
      }
      if count > 0 {
        let remaining = maximumBytes - output.count
        let accepted = min(remaining, count)
        if accepted > 0 {
          output.append(contentsOf: buffer.prefix(accepted))
        }
        if accepted < count {
          return (false, true)
        }
        continue
      }
      if count == 0 {
        return (true, false)
      }
      if errno == EINTR {
        continue
      }
      if errno == EAGAIN || errno == EWOULDBLOCK {
        return (false, false)
      }
      throw ProcessExecutionError.ioFailure
    }
  }

  private func termination(from status: Int32) -> ProcessTermination {
    let signal = status & 0x7f
    if signal == 0 {
      return .exited(code: (status >> 8) & 0xff)
    }
    return .signaled(signal: signal)
  }

  private func elapsedMilliseconds(since startedAt: UInt64) -> UInt64 {
    let current = DispatchTime.now().uptimeNanoseconds
    guard current >= startedAt else {
      return 0
    }
    return (current - startedAt) / 1_000_000
  }
}
