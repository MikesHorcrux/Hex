import Darwin

/// Immutable syscall boundary for owned-child cleanup, with errno captured before other work.
struct MCPProcessCleanupSystemCalls: Sendable {
  let sendSignal: @Sendable (pid_t, Int32) -> (result: Int32, error: Int32)
  let observeExit:
    @Sendable (pid_t) -> (result: Int32, error: Int32, processID: pid_t, signal: Int32)
  let waitForLeader: @Sendable (pid_t) -> (result: pid_t, error: Int32, status: Int32)

  static var live: Self {
    Self(
      sendSignal: { processID, signal in
        let result = Darwin.kill(processID, signal)
        let error = result == 0 ? 0 : errno
        return (result, error)
      },
      observeExit: { processID in
        var information = siginfo_t()
        let result = waitid(
          P_PID,
          id_t(processID),
          &information,
          WEXITED | WNOHANG | WNOWAIT
        )
        let error = result == 0 ? 0 : errno
        return (result, error, information.si_pid, information.si_signo)
      },
      waitForLeader: { processID in
        var status = Int32(0)
        let result = waitpid(processID, &status, 0)
        let error = result < 0 ? errno : 0
        return (result, error, status)
      }
    )
  }
}
