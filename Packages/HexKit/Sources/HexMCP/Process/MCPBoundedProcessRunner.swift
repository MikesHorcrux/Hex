import Darwin
import Dispatch
import Foundation

/// Runs a single local command through Hex's hardened executable-snapshot process boundary.
public actor MCPBoundedProcessRunner {
  private static let pollingIntervalMilliseconds: Int64 = 5
  private static let maximumCachedExecutableSnapshots = 4

  private let timeoutMilliseconds: UInt64
  private let maximumOutputBytes: Int
  private let maximumErrorBytes: Int
  private let spawnProcess:
    @Sendable (MCPServerConfiguration, MCPExecutableSnapshot?) throws -> MCPSpawnedProcess
  private let terminateProcess: @Sendable (pid_t, Bool) throws -> Int32
  private var executableSnapshots: [String: MCPExecutableSnapshot] = [:]
  private var executableSnapshotRecency: [String] = []

  public init(
    timeoutMilliseconds: UInt64 = 30_000,
    maximumOutputBytes: Int = 64 * 1_024,
    maximumErrorBytes: Int = 64 * 1_024
  ) {
    self.timeoutMilliseconds = timeoutMilliseconds
    self.maximumOutputBytes = maximumOutputBytes
    self.maximumErrorBytes = maximumErrorBytes
    spawnProcess = { configuration, reusableExecutableSnapshot in
      try MCPStdioProcessSpawner.spawn(
        configuration,
        reusableExecutableSnapshot: reusableExecutableSnapshot
      )
    }
    terminateProcess = { processID, leaderHasExited in
      try Self.terminateAndReap(processID, leaderHasExited: leaderHasExited)
    }
  }

  init(
    timeoutMilliseconds: UInt64,
    maximumOutputBytes: Int,
    maximumErrorBytes: Int,
    spawnProcess:
      @escaping @Sendable (
        MCPServerConfiguration,
        MCPExecutableSnapshot?
      ) throws -> MCPSpawnedProcess,
    terminateProcess: @escaping @Sendable (pid_t, Bool) throws -> Int32 = {
      processID,
      leaderHasExited in
      try MCPBoundedProcessRunner.terminateAndReap(
        processID,
        leaderHasExited: leaderHasExited
      )
    }
  ) {
    self.timeoutMilliseconds = timeoutMilliseconds
    self.maximumOutputBytes = maximumOutputBytes
    self.maximumErrorBytes = maximumErrorBytes
    self.spawnProcess = spawnProcess
    self.terminateProcess = terminateProcess
  }

  public func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String] = [:],
    workingDirectoryURL: URL = URL(fileURLWithPath: "/", isDirectory: true)
  ) async throws -> MCPBoundedProcessResult {
    try Task.checkCancellation()
    let startedAt = DispatchTime.now().uptimeNanoseconds
    guard
      (1...300_000).contains(timeoutMilliseconds),
      (1_024...8 * 1_024 * 1_024).contains(maximumOutputBytes),
      (0...1 * 1_024 * 1_024).contains(maximumErrorBytes)
    else {
      throw MCPServerConfigurationError.invalidLimit
    }
    let configuration = try MCPServerConfiguration(
      serverID: "bounded-command",
      executableURL: executableURL,
      arguments: arguments,
      workingDirectory: workingDirectoryURL,
      environment: environment,
      requestTimeoutMilliseconds: timeoutMilliseconds,
      shutdownGraceMilliseconds: 250,
      maximumMessageBytes: maximumOutputBytes,
      maximumStderrBytes: maximumErrorBytes,
      maximumToolPages: 1,
      maximumTools: 1,
      maximumContentItems: 1,
      maximumArgumentsBytes: 1_024
    )
    let executablePath = configuration.executableURL.path
    var reusableExecutableSnapshot = executableSnapshots[executablePath]
    if let snapshot = reusableExecutableSnapshot,
      !snapshot.isIntact() || !snapshot.sourceIsIntact(at: executablePath)
    {
      removeCachedExecutableSnapshot(for: executablePath)
      reusableExecutableSnapshot = nil
    }
    if reusableExecutableSnapshot == nil {
      makeExecutableSnapshotCacheSpace()
    } else {
      recordExecutableSnapshotUse(executablePath)
    }
    let process: MCPSpawnedProcess
    do {
      process = try spawnProcess(configuration, reusableExecutableSnapshot)
    } catch {
      let cachedSnapshotBecameInvalid =
        reusableExecutableSnapshot.map {
          !$0.isIntact() || !$0.sourceIsIntact(at: executablePath)
        } ?? false
      guard cachedSnapshotBecameInvalid else { throw error }
      removeCachedExecutableSnapshot(for: executablePath)
      reusableExecutableSnapshot = nil
      makeExecutableSnapshotCacheSpace()
      process = try spawnProcess(configuration, nil)
    }
    if let snapshot = process.executableSnapshot {
      executableSnapshots[executablePath] = snapshot
      recordExecutableSnapshotUse(executablePath)
    }
    return try await Self.monitor(
      process,
      timeoutMilliseconds: timeoutMilliseconds,
      maximumOutputBytes: maximumOutputBytes,
      maximumErrorBytes: maximumErrorBytes,
      startedAt: startedAt,
      terminateProcess: terminateProcess
    )
  }

  private func makeExecutableSnapshotCacheSpace() {
    while executableSnapshots.count >= Self.maximumCachedExecutableSnapshots,
      let leastRecentlyUsedPath = executableSnapshotRecency.first
    {
      removeCachedExecutableSnapshot(for: leastRecentlyUsedPath)
    }
  }

  private func recordExecutableSnapshotUse(_ executablePath: String) {
    executableSnapshotRecency.removeAll { $0 == executablePath }
    executableSnapshotRecency.append(executablePath)
  }

  private func removeCachedExecutableSnapshot(for executablePath: String) {
    executableSnapshots.removeValue(forKey: executablePath)
    executableSnapshotRecency.removeAll { $0 == executablePath }
  }

  private static func monitor(
    _ process: MCPSpawnedProcess,
    timeoutMilliseconds: UInt64,
    maximumOutputBytes: Int,
    maximumErrorBytes: Int,
    startedAt: UInt64,
    terminateProcess: @Sendable (pid_t, Bool) throws -> Int32
  ) async throws -> MCPBoundedProcessResult {
    var standardOutput = Data()
    var standardError = Data()
    var outputReachedEnd = false
    var errorReachedEnd = false
    var leaderHasExited = false
    var leaderMayHaveBeenReaped = false
    var cleanupAttempted = false
    let (timeoutNanoseconds, multiplicationOverflowed) =
      timeoutMilliseconds.multipliedReportingOverflow(by: 1_000_000)
    let (deadline, additionOverflowed) =
      startedAt.addingReportingOverflow(timeoutNanoseconds)

    Darwin.close(process.inputDescriptor)
    defer {
      Darwin.close(process.outputDescriptor)
      Darwin.close(process.errorDescriptor)
    }

    guard !multiplicationOverflowed, !additionOverflowed else {
      cleanupAttempted = true
      _ = try terminateProcess(process.processID, false)
      throw MCPServerConfigurationError.invalidLimit
    }

    do {
      while true {
        try Task.checkCancellation()
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
          throw MCPClientSessionError.requestTimedOut
        }

        if !outputReachedEnd {
          let result = try drain(
            process.outputDescriptor,
            into: &standardOutput,
            maximumBytes: maximumOutputBytes
          )
          outputReachedEnd = result.reachedEndOfFile
          if result.exceededLimit {
            throw MCPClientSessionError.limitExceeded
          }
        }
        if !errorReachedEnd {
          let result = try drain(
            process.errorDescriptor,
            into: &standardError,
            maximumBytes: maximumErrorBytes
          )
          errorReachedEnd = result.reachedEndOfFile
          if result.exceededLimit {
            throw MCPClientSessionError.limitExceeded
          }
        }

        if !leaderHasExited {
          leaderHasExited = try observeExit(
            process.processID,
            leaderMayHaveBeenReaped: &leaderMayHaveBeenReaped
          )
        }
        if leaderHasExited && outputReachedEnd && errorReachedEnd {
          cleanupAttempted = true
          let waitStatus = try terminateProcess(
            process.processID,
            true
          )
          return MCPBoundedProcessResult(
            status: normalizedTerminationStatus(waitStatus),
            standardOutput: standardOutput,
            standardError: standardError
          )
        }
        try await Task.sleep(for: .milliseconds(Self.pollingIntervalMilliseconds))
      }
    } catch is CancellationError {
      if !cleanupAttempted {
        cleanupAttempted = true
        try cleanupAfterFailure(
          process.processID,
          leaderHasExited: leaderHasExited,
          leaderMayHaveBeenReaped: leaderMayHaveBeenReaped,
          terminateProcess: terminateProcess
        )
      }
      throw CancellationError()
    } catch {
      if !cleanupAttempted {
        cleanupAttempted = true
        do {
          try cleanupAfterFailure(
            process.processID,
            leaderHasExited: leaderHasExited,
            leaderMayHaveBeenReaped: leaderMayHaveBeenReaped,
            terminateProcess: terminateProcess
          )
        } catch {
          throw MCPClientSessionError.connectionClosed
        }
      }
      throw error
    }
  }

  private static func drain(
    _ descriptor: Int32,
    into data: inout Data,
    maximumBytes: Int
  ) throws -> MCPBoundedProcessRunnerDrainResult {
    var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
    while true {
      try Task.checkCancellation()
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
      }
      if count > 0 {
        let accepted = min(maximumBytes - data.count, count)
        if accepted > 0 {
          data.append(contentsOf: buffer.prefix(accepted))
        }
        if accepted < count {
          return MCPBoundedProcessRunnerDrainResult(reachedEndOfFile: false, exceededLimit: true)
        }
        continue
      }
      if count == 0 {
        return MCPBoundedProcessRunnerDrainResult(reachedEndOfFile: true, exceededLimit: false)
      }
      if errno == EINTR { continue }
      if errno == EAGAIN || errno == EWOULDBLOCK {
        return MCPBoundedProcessRunnerDrainResult(reachedEndOfFile: false, exceededLimit: false)
      }
      throw MCPClientSessionError.connectionClosed
    }
  }

  /// Observes the leader without reaping it so its PID cannot be recycled before group cleanup.
  private static func observeExit(
    _ processID: pid_t,
    leaderMayHaveBeenReaped: inout Bool,
    systemCalls: MCPProcessCleanupSystemCalls = .live
  ) throws -> Bool {
    let observation = systemCalls.observeExit(processID)
    guard observation.result == 0 else {
      if observation.error == EINTR { return false }
      if observation.error == ECHILD { leaderMayHaveBeenReaped = true }
      throw MCPClientSessionError.connectionClosed
    }
    return observation.signal == SIGCHLD && observation.processID == processID
  }

  private static func cleanupAfterFailure(
    _ processID: pid_t,
    leaderHasExited: Bool,
    leaderMayHaveBeenReaped: Bool,
    terminateProcess: @Sendable (pid_t, Bool) throws -> Int32
  ) throws {
    guard !leaderMayHaveBeenReaped else {
      throw MCPClientSessionError.connectionClosed
    }
    _ = try terminateProcess(processID, leaderHasExited)
  }

  /// Signals the owned process group before reaping its leader, including after ordinary exit.
  static func terminateAndReap(
    _ processID: pid_t,
    leaderHasExited: Bool = false,
    systemCalls: MCPProcessCleanupSystemCalls = .live
  ) throws -> Int32 {
    guard processID > 0 else {
      throw MCPClientSessionError.connectionClosed
    }

    var cleanupFailed = false
    var observedLeaderExit = leaderHasExited
    let groupSignal = systemCalls.sendSignal(-processID, SIGKILL)
    let groupSignalResult = groupSignal.result
    let groupSignalError = groupSignal.error
    if groupSignalResult < 0,
      groupSignalError == EPERM,
      !observedLeaderExit
    {
      var leaderMayHaveBeenReaped = false
      observedLeaderExit = try observeExit(
        processID,
        leaderMayHaveBeenReaped: &leaderMayHaveBeenReaped,
        systemCalls: systemCalls
      )
      guard !leaderMayHaveBeenReaped else {
        throw MCPClientSessionError.connectionClosed
      }
    }
    // An exiting leader can make group signaling return EPERM before waitid observes its exit.
    // Defer that result until the owned leader is reaped and the group probe proves absence.
    let groupSignalPermissionDenied = groupSignalResult < 0 && groupSignalError == EPERM
    if groupSignalResult < 0,
      groupSignalError != ESRCH,
      !groupSignalPermissionDenied
    {
      cleanupFailed = true
    }

    if !observedLeaderExit || groupSignalPermissionDenied {
      let leaderSignal = systemCalls.sendSignal(processID, SIGKILL)
      let leaderSignalResult = leaderSignal.result
      let leaderSignalError = leaderSignal.error
      if leaderSignalResult < 0, leaderSignalError != ESRCH {
        cleanupFailed = true
      }
    }

    var status = Int32(0)
    var didReap = false
    while true {
      let wait = systemCalls.waitForLeader(processID)
      let waitResult = wait.result
      status = wait.status
      if waitResult == processID {
        didReap = true
        break
      }
      if waitResult < 0, wait.error == EINTR { continue }
      cleanupFailed = true
      break
    }

    if didReap, groupSignalPermissionDenied {
      let groupProbe = systemCalls.sendSignal(-processID, 0)
      let groupProbeResult = groupProbe.result
      let groupProbeError = groupProbe.error
      if !(groupProbeResult < 0 && groupProbeError == ESRCH) {
        cleanupFailed = true
      }
    }

    guard didReap, !cleanupFailed else {
      throw MCPClientSessionError.connectionClosed
    }
    return status
  }

  private static func normalizedTerminationStatus(_ status: Int32) -> Int32 {
    let signal = status & 0x7f
    if signal != 0 {
      return 128 + signal
    }
    return (status >> 8) & 0xff
  }

}
