import Darwin
import Foundation

extension POSIXProcessExecutor {
  func monitor(
    _ process: SpawnedProcess,
    timeoutSeconds: Int,
    startedAt: UInt64
  ) async throws -> ProcessExecutionResult {
    var output = Data()
    var waitStatus: Int32?
    var reachedEndOfFile = false
    let timeoutNanoseconds = UInt64(timeoutSeconds) * 1_000_000_000
    let (deadline, deadlineOverflowed) = startedAt.addingReportingOverflow(timeoutNanoseconds)
    guard !deadlineOverflowed else {
      terminateAndReap(process.processID)
      Darwin.close(process.outputDescriptor)
      throw ProcessExecutionError.invalidRequest
    }

    defer { Darwin.close(process.outputDescriptor) }
    do {
      while true {
        try Task.checkCancellation()
        let drainResult = try drain(
          process.outputDescriptor,
          into: &output,
          maximumBytes: configuration.maximumOutputBytes
        )
        reachedEndOfFile = reachedEndOfFile || drainResult.reachedEndOfFile
        if drainResult.exceededLimit {
          terminateAndReap(process.processID, unlessAlreadyReaped: waitStatus != nil)
          return ProcessExecutionResult(
            termination: .outputLimitExceeded,
            output: output,
            durationMilliseconds: elapsedMilliseconds(since: startedAt)
          )
        }

        if waitStatus == nil {
          var status = Int32(0)
          let waitResult = waitpid(process.processID, &status, WNOHANG)
          if waitResult == process.processID {
            waitStatus = status
          } else if waitResult < 0, errno != EINTR {
            throw ProcessExecutionError.ioFailure
          }
        }

        if let waitStatus, reachedEndOfFile {
          return ProcessExecutionResult(
            termination: termination(from: waitStatus),
            output: output,
            durationMilliseconds: elapsedMilliseconds(since: startedAt)
          )
        }

        if DispatchTime.now().uptimeNanoseconds >= deadline {
          terminateAndReap(process.processID, unlessAlreadyReaped: waitStatus != nil)
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
      terminateAndReap(process.processID, unlessAlreadyReaped: waitStatus != nil)
      throw CancellationError()
    } catch {
      terminateAndReap(process.processID, unlessAlreadyReaped: waitStatus != nil)
      throw error
    }
  }

  func terminateAndReap(
    _ processID: pid_t,
    unlessAlreadyReaped alreadyReaped: Bool = false
  ) {
    guard processID > 0 else {
      return
    }
    if Darwin.kill(-processID, SIGKILL) != 0, errno != ESRCH {
      _ = Darwin.kill(processID, SIGKILL)
    }
    guard !alreadyReaped else {
      return
    }
    var status = Int32(0)
    while waitpid(processID, &status, 0) < 0, errno == EINTR {}
  }

  private func drain(
    _ descriptor: Int32,
    into output: inout Data,
    maximumBytes: Int
  ) throws -> (reachedEndOfFile: Bool, exceededLimit: Bool) {
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
      }
      if count > 0 {
        let remaining = maximumBytes - output.count
        let accepted = min(remaining, count)
        if accepted > 0 {
          output.append(buffer, count: accepted)
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
