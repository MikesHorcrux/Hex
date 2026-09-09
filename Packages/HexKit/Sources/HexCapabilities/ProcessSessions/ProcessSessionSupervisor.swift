import Darwin
import Foundation

/// Early executable mode: no resident, provider, database, UI, or Keychain initialization.
/// Every child is spawned, never forked into a live Swift runtime.
public enum ProcessSessionSupervisor {
  public static func runIfRequested(_ arguments: [String]) -> Bool {
    if arguments == ["--hex-process-terminal-child"] { terminalChild() }
    guard arguments == ["--hex-process-supervisor"] else { return false }
    do {
      guard Darwin.setpgid(0, 0) == 0 || getpgrp() == getpid() else {
        throw ProcessSessionErrorBridge.invalid
      }
      // Ignore SIGPIPE in this disposable process only; a lost owner must still trigger cleanup.
      Darwin.signal(SIGPIPE, SIG_IGN)
      // Retain the leader as a waitable zombie until group cleanup; ignored SIGCHLD could reap it
      // automatically and remove the PID-reuse fence.
      Darwin.signal(SIGCHLD, SIG_DFL)
      let requestData = try readConfiguration()
      let request = try JSONDecoder().decode(ProcessSupervisorRequest.self, from: requestData)
      try supervise(request)
    } catch {
      let message = ProcessSupervisorMessage(
        kind: "failure", detail: "Supervisor startup or cleanup failed.")
      if let data = try? JSONEncoder().encode(message) {
        _ = data.withUnsafeBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count) }
        var newline: UInt8 = 10
        _ = Darwin.write(STDOUT_FILENO, &newline, 1)
      }
    }
    return true
  }

  static func readConfiguration(descriptor: Int32 = STDIN_FILENO) throws -> Data {
    var data = Data()
    var byte: UInt8 = 0
    while data.count < 256 * 1_024 {
      let count = Darwin.read(descriptor, &byte, 1)
      if count < 0 && errno == EINTR { continue }
      guard count == 1 else { throw ProcessSessionErrorBridge.invalid }
      if byte == 10 { return data }
      data.append(byte)
    }
    throw ProcessSessionErrorBridge.invalid
  }
}
