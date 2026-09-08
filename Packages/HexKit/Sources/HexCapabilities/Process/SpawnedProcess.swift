import Darwin

/// Internal process state owned exclusively by `POSIXProcessExecutor`.
///
/// The executor owns signaling and reaping `processID`; unrelated Hex code must not call
/// `waitpid` or `waitid` for it. Darwin's `WNOWAIT` only observes an exited child and does not lock
/// it against another reaper, so external reaping is outside this lifecycle contract and leaves
/// cleanup unable to prove the process-group identity.
struct SpawnedProcess: Sendable {
  let processID: pid_t
  let outputDescriptor: Int32
}
