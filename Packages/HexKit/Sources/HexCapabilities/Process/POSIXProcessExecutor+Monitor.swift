import Darwin
import Foundation

extension POSIXProcessExecutor {
  func monitor(
    _ process: SpawnedProcess,
    timeoutSeconds: Int,
    startedAt: UInt64,
    capture initialCapture: ProcessOutputCapture
  ) async throws -> ProcessExecutionResult {
    var capture = initialCapture
    var leaderHasExited = false
    var leaderMayHaveBeenReaped = false
    var cleanupAttempted = false
    let timeoutNanoseconds = UInt64(timeoutSeconds) * 1_000_000_000
    let (deadline, deadlineOverflowed) = startedAt.addingReportingOverflow(timeoutNanoseconds)

    defer { Darwin.close(process.outputDescriptor) }
    guard !deadlineOverflowed else {
      cleanupAttempted = true
      _ = try terminateAndReap(process.processID)
      await capture.retainInterruptedOutput()
      throw ProcessExecutionError.invalidRequest
    }

    do {
      while true {
        try Task.checkCancellation()
        let drainResult = try drainBatch(process.outputDescriptor)
        let reachedEndOfFile = drainResult.reachedEndOfFile
        let accepted = drainResult.data.isEmpty ? true : try await capture.append(drainResult.data)
        if !accepted {
          cleanupAttempted = true
          _ = try terminateAndReap(
            process.processID,
            leaderHasExited: leaderHasExited
          )
          return await capture.finish(
            termination: capture.failure == nil ? .outputLimitExceeded : .outputCaptureFailed,
            durationMilliseconds: elapsedMilliseconds(since: startedAt), reachedEOF: false
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
          return await capture.finish(
            termination: termination(from: status),
            durationMilliseconds: elapsedMilliseconds(since: startedAt), reachedEOF: true
          )
        }

        if DispatchTime.now().uptimeNanoseconds >= deadline {
          cleanupAttempted = true
          _ = try terminateAndReap(
            process.processID,
            leaderHasExited: leaderHasExited
          )
          return await capture.finish(
            termination: .timedOut,
            durationMilliseconds: elapsedMilliseconds(since: startedAt), reachedEOF: false
          )
        }
        if drainResult.data.isEmpty {
          try await Task.sleep(for: .milliseconds(configuration.pollingIntervalMilliseconds))
        } else {
          // Continuous output must return to deadline/cancellation checks after every bounded
          // append, rather than draining a permanently readable pipe until EAGAIN.
          await Task.yield()
        }
      }
    } catch is CancellationError {
      do {
        if !cleanupAttempted {
          cleanupAttempted = true
          guard !leaderMayHaveBeenReaped else { throw ProcessExecutionError.cleanupFailed }
          _ = try terminateAndReap(process.processID, leaderHasExited: leaderHasExited)
        }
      } catch {
        await capture.retainInterruptedOutput()
        throw error
      }
      // The owned leader is reaped and cleanup is known. Return the partial-output receipt so the
      // runtime can commit toolFinished before its next cancellation checkpoint ends the run.
      return await capture.finish(
        termination: .cancelled, durationMilliseconds: elapsedMilliseconds(since: startedAt),
        reachedEOF: false)
    } catch {
      if !cleanupAttempted {
        cleanupAttempted = true
        guard !leaderMayHaveBeenReaped else {
          await capture.retainInterruptedOutput()
          throw ProcessExecutionError.cleanupFailed
        }
        do {
          _ = try terminateAndReap(
            process.processID,
            leaderHasExited: leaderHasExited
          )
        } catch let cleanupError {
          await capture.retainInterruptedOutput()
          throw cleanupError
        }
      }
      if error as? ProcessExecutionError == .ioFailure {
        capture.markReadFailure()
        return await capture.finish(
          termination: .outputCaptureFailed,
          durationMilliseconds: elapsedMilliseconds(since: startedAt), reachedEOF: false)
      }
      await capture.retainInterruptedOutput()
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

  private func drainBatch(_ descriptor: Int32) throws -> (data: Data, reachedEndOfFile: Bool) {
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    for _ in 0..<4 {
      try Task.checkCancellation()
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
      }
      if count > 0 {
        return (Data(buffer.prefix(count)), false)
      }
      if count == 0 {
        return (Data(), true)
      }
      if errno == EINTR {
        continue
      }
      if errno == EAGAIN || errno == EWOULDBLOCK {
        return (Data(), false)
      }
      throw ProcessExecutionError.ioFailure
    }
    return (Data(), false)
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
