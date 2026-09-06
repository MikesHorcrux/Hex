import Darwin
import Foundation
import Synchronization
import Testing

@testable import HexMCP

@Suite("Bounded process runner")
struct MCPBoundedProcessRunnerTests {
  @Test("Successful output permits an empty standard error stream")
  func acceptsEmptyStandardError() async throws {
    let runner = MCPBoundedProcessRunner()

    let result = try await runner.run(
      executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
      arguments: ["%s", "ready\n"],
      environment: ["PATH": "/usr/bin:/bin"]
    )

    #expect(result.status == 0)
    #expect(String(data: result.standardOutput, encoding: .utf8) == "ready\n")
    #expect(result.standardError.isEmpty)
  }

  @Test("Exactly the stdout byte limit succeeds")
  func acceptsExactOutputLimit() async throws {
    let runner = MCPBoundedProcessRunner(
      maximumOutputBytes: 1_024,
      maximumErrorBytes: 1_024
    )

    let result = try await runner.run(
      executableURL: URL(fileURLWithPath: "/usr/bin/awk"),
      arguments: ["BEGIN { for (i = 0; i < 1024; i++) printf \"a\" }"],
      environment: ["PATH": "/usr/bin:/bin"]
    )

    #expect(result.status == 0)
    #expect(result.standardOutput.count == 1_024)
    #expect(result.standardError.isEmpty)
  }

  @Test("One stdout byte beyond the limit fails closed and reaps")
  func rejectsOutputBeyondLimit() async throws {
    let recorder = ProcessRecorder()
    let runner = makeRunner(
      recorder: recorder,
      maximumOutputBytes: 1_024
    )

    await #expect(throws: MCPClientSessionError.limitExceeded) {
      _ = try await runner.run(
        executableURL: URL(fileURLWithPath: "/usr/bin/awk"),
        arguments: ["BEGIN { for (i = 0; i < 1025; i++) printf \"a\" }"],
        environment: ["PATH": "/usr/bin:/bin"]
      )
    }
    let processID = try #require(recorder.processID)
    #expect(Self.wasReaped(processID))
  }

  @Test("Exactly the stderr byte limit succeeds")
  func acceptsExactErrorLimit() async throws {
    let runner = MCPBoundedProcessRunner(
      maximumOutputBytes: 1_024,
      maximumErrorBytes: 1_024
    )

    let result = try await runner.run(
      executableURL: URL(fileURLWithPath: "/usr/bin/awk"),
      arguments: [
        "BEGIN { for (i = 0; i < 1024; i++) printf \"e\" > \"/dev/stderr\" }"
      ],
      environment: ["PATH": "/usr/bin:/bin"]
    )

    #expect(result.status == 0)
    #expect(result.standardOutput.isEmpty)
    #expect(result.standardError.count == 1_024)
  }

  @Test("One stderr byte beyond the limit fails closed and reaps")
  func rejectsErrorBeyondLimit() async throws {
    let recorder = ProcessRecorder()
    let runner = makeRunner(
      recorder: recorder,
      maximumErrorBytes: 1_024
    )

    await #expect(throws: MCPClientSessionError.limitExceeded) {
      _ = try await runner.run(
        executableURL: URL(fileURLWithPath: "/usr/bin/awk"),
        arguments: [
          "BEGIN { for (i = 0; i < 1025; i++) printf \"e\" > \"/dev/stderr\" }"
        ],
        environment: ["PATH": "/usr/bin:/bin"]
      )
    }
    let processID = try #require(recorder.processID)
    #expect(Self.wasReaped(processID))
  }

  @Test("A mutable executable runs from a secured snapshot")
  func snapshotsMutableExecutable() async throws {
    let snapshotNamespace = "hex-bounded-runner-\(UUID().uuidString)"
    let snapshotNamespaceURL = URL(
      fileURLWithPath: "/private/tmp/\(snapshotNamespace)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: snapshotNamespaceURL) }
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MCPBoundedProcessRunnerTests-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(
      at: rootURL,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    let executableURL = rootURL.appendingPathComponent("fixture")
    try compileFixture(at: executableURL)
    let recorder = ExecutionPathRecorder()
    let runner = MCPBoundedProcessRunner(
      timeoutMilliseconds: 30_000,
      maximumOutputBytes: 64 * 1_024,
      maximumErrorBytes: 64 * 1_024,
      spawnProcess: { configuration, reusableExecutableSnapshot in
        try MCPStdioProcessSpawner.spawn(
          configuration,
          reusableExecutableSnapshot: reusableExecutableSnapshot,
          executableSnapshotNamespaceBasename: snapshotNamespace,
          beforeExecution: { configuredPath, launchPath in
            recorder.record(configuredPath: configuredPath, launchPath: launchPath)
          }
        )
      }
    )

    for _ in 0..<3 {
      let result = try await runner.run(
        executableURL: executableURL,
        arguments: [],
        environment: ["PATH": "/usr/bin:/bin"]
      )
      #expect(result.status == 0)
      #expect(String(data: result.standardOutput, encoding: .utf8) == "snapshot-ready")
    }

    #expect(recorder.configuredPath == executableURL.path)
    #expect(recorder.launchPath != executableURL.path)
    #expect(recorder.launchPaths.count == 3)
    #expect(Set(recorder.launchPaths).count == 1)
    let retainedEntries = try FileManager.default.contentsOfDirectory(
      at: snapshotNamespaceURL,
      includingPropertiesForKeys: [.isDirectoryKey]
    )
    let retainedSlots = try retainedEntries.filter {
      try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
    }
    #expect(retainedSlots.count == 1)
  }

  @Test("Concurrent first runs share one mutable executable snapshot slot")
  func concurrentRunsShareSnapshot() async throws {
    let snapshotNamespace = "hex-bounded-runner-\(UUID().uuidString)"
    let snapshotNamespaceURL = URL(
      fileURLWithPath: "/private/tmp/\(snapshotNamespace)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: snapshotNamespaceURL) }
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MCPBoundedProcessRunnerTests-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(
      at: rootURL,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    let executableURL = rootURL.appendingPathComponent("fixture")
    try compileFixture(at: executableURL)
    let recorder = ExecutionPathRecorder()
    let runner = MCPBoundedProcessRunner(
      timeoutMilliseconds: 30_000,
      maximumOutputBytes: 64 * 1_024,
      maximumErrorBytes: 64 * 1_024,
      spawnProcess: { configuration, reusableExecutableSnapshot in
        try MCPStdioProcessSpawner.spawn(
          configuration,
          reusableExecutableSnapshot: reusableExecutableSnapshot,
          executableSnapshotNamespaceBasename: snapshotNamespace,
          beforeExecution: { configuredPath, launchPath in
            recorder.record(configuredPath: configuredPath, launchPath: launchPath)
          }
        )
      }
    )

    try await withThrowingTaskGroup(of: Int32.self) { group in
      for _ in 0..<4 {
        group.addTask {
          let result = try await runner.run(
            executableURL: executableURL,
            arguments: [],
            environment: ["PATH": "/usr/bin:/bin"]
          )
          return result.status
        }
      }
      for try await status in group {
        #expect(status == 0)
      }
    }

    #expect(recorder.launchPaths.count == 4)
    #expect(Set(recorder.launchPaths).count == 1)
    let retainedEntries = try FileManager.default.contentsOfDirectory(
      at: snapshotNamespaceURL,
      includingPropertiesForKeys: [.isDirectoryKey]
    )
    let retainedSlots = try retainedEntries.filter {
      try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
    }
    #expect(retainedSlots.count == 1)
  }

  @Test("An invalid cached snapshot is replaced on the next run")
  func invalidCachedSnapshotSelfHeals() async throws {
    let snapshotNamespace = "hex-bounded-runner-\(UUID().uuidString)"
    let snapshotNamespaceURL = URL(
      fileURLWithPath: "/private/tmp/\(snapshotNamespace)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: snapshotNamespaceURL) }
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MCPBoundedProcessRunnerTests-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(
      at: rootURL,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    let executableURL = rootURL.appendingPathComponent("fixture")
    try compileFixture(at: executableURL)
    let recorder = ExecutionPathRecorder()
    let runner = MCPBoundedProcessRunner(
      timeoutMilliseconds: 30_000,
      maximumOutputBytes: 64 * 1_024,
      maximumErrorBytes: 64 * 1_024,
      spawnProcess: { configuration, reusableExecutableSnapshot in
        try MCPStdioProcessSpawner.spawn(
          configuration,
          reusableExecutableSnapshot: reusableExecutableSnapshot,
          executableSnapshotNamespaceBasename: snapshotNamespace,
          beforeExecution: { configuredPath, launchPath in
            recorder.record(configuredPath: configuredPath, launchPath: launchPath)
          }
        )
      }
    )

    let first = try await runner.run(
      executableURL: executableURL,
      arguments: [],
      environment: ["PATH": "/usr/bin:/bin"]
    )
    #expect(first.status == 0)
    let firstLaunchPath = try #require(recorder.launchPath)
    let firstSlotURL = URL(fileURLWithPath: firstLaunchPath).deletingLastPathComponent()
    let movedSlotURL = snapshotNamespaceURL.appendingPathComponent(
      "moved-invalid-cached-slot",
      isDirectory: true
    )
    #expect(Darwin.rename(firstSlotURL.path, movedSlotURL.path) == 0)

    let second = try await runner.run(
      executableURL: executableURL,
      arguments: [],
      environment: ["PATH": "/usr/bin:/bin"]
    )

    #expect(second.status == 0)
    #expect(String(data: second.standardOutput, encoding: .utf8) == "snapshot-ready")
    #expect(recorder.launchPaths.count == 2)
    #expect(FileManager.default.fileExists(atPath: recorder.launchPaths[1]))
  }

  @Test("Replacing a mutable executable at the same path rebuilds its cached snapshot")
  func sourceReplacementRebuildsCachedSnapshot() async throws {
    let snapshotNamespace = "hex-bounded-runner-\(UUID().uuidString)"
    let snapshotNamespaceURL = URL(
      fileURLWithPath: "/private/tmp/\(snapshotNamespace)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: snapshotNamespaceURL) }
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MCPBoundedProcessRunnerTests-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(
      at: rootURL,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    let executableURL = rootURL.appendingPathComponent("fixture")
    let replacementURL = rootURL.appendingPathComponent("replacement")
    try compileFixture(at: executableURL, output: "snapshot-ready")
    try compileFixture(at: replacementURL, output: "replacement-ready")
    let runner = MCPBoundedProcessRunner(
      timeoutMilliseconds: 30_000,
      maximumOutputBytes: 64 * 1_024,
      maximumErrorBytes: 64 * 1_024,
      spawnProcess: { configuration, reusableExecutableSnapshot in
        try MCPStdioProcessSpawner.spawn(
          configuration,
          reusableExecutableSnapshot: reusableExecutableSnapshot,
          executableSnapshotNamespaceBasename: snapshotNamespace
        )
      }
    )

    let first = try await runner.run(
      executableURL: executableURL,
      arguments: [],
      environment: ["PATH": "/usr/bin:/bin"]
    )
    #expect(String(data: first.standardOutput, encoding: .utf8) == "snapshot-ready")

    #expect(Darwin.rename(replacementURL.path, executableURL.path) == 0)
    let second = try await runner.run(
      executableURL: executableURL,
      arguments: [],
      environment: ["PATH": "/usr/bin:/bin"]
    )

    #expect(second.status == 0)
    #expect(String(data: second.standardOutput, encoding: .utf8) == "replacement-ready")
  }

  @Test("Distinct executable cache entries cannot pin the entire snapshot namespace")
  func distinctExecutableCacheEntriesAreEvicted() async throws {
    let snapshotNamespace = "hex-bounded-runner-\(UUID().uuidString)"
    let snapshotNamespaceURL = URL(
      fileURLWithPath: "/private/tmp/\(snapshotNamespace)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: snapshotNamespaceURL) }
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MCPBoundedProcessRunnerTests-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(
      at: rootURL,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    let fixtureURL = rootURL.appendingPathComponent("fixture-template")
    try compileFixture(at: fixtureURL)
    let runner = MCPBoundedProcessRunner(
      timeoutMilliseconds: 30_000,
      maximumOutputBytes: 64 * 1_024,
      maximumErrorBytes: 64 * 1_024,
      spawnProcess: { configuration, reusableExecutableSnapshot in
        try MCPStdioProcessSpawner.spawn(
          configuration,
          reusableExecutableSnapshot: reusableExecutableSnapshot,
          executableSnapshotNamespaceBasename: snapshotNamespace
        )
      }
    )

    for index in 0..<36 {
      let executableURL = rootURL.appendingPathComponent("fixture-\(index)")
      try FileManager.default.copyItem(at: fixtureURL, to: executableURL)
      let result = try await runner.run(
        executableURL: executableURL,
        arguments: [],
        environment: ["PATH": "/usr/bin:/bin"]
      )
      #expect(result.status == 0)
      #expect(String(data: result.standardOutput, encoding: .utf8) == "snapshot-ready")
    }

    let retainedEntries = try FileManager.default.contentsOfDirectory(
      at: snapshotNamespaceURL,
      includingPropertiesForKeys: [.isDirectoryKey]
    )
    let retainedSlots = try retainedEntries.filter {
      try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
    }
    #expect(retainedSlots.count <= 4)
  }

  @Test("A nonzero exit is returned after the process is reaped")
  func returnsNonzeroExit() async throws {
    let recorder = ProcessRecorder()
    let runner = makeRunner(recorder: recorder)

    let result = try await runner.run(
      executableURL: URL(fileURLWithPath: "/usr/bin/false"),
      arguments: [],
      environment: ["PATH": "/usr/bin:/bin"]
    )

    #expect(result.status == 1)
    let processID = try #require(recorder.processID)
    #expect(Self.wasReaped(processID))
  }

  @Test("The stdout limit kills and reaps a still-running producer")
  func outputLimitCleansUpProcess() async throws {
    let recorder = ProcessRecorder()
    let runner = makeRunner(
      recorder: recorder,
      maximumOutputBytes: 1_024
    )

    await #expect(throws: MCPClientSessionError.limitExceeded) {
      _ = try await runner.run(
        executableURL: URL(fileURLWithPath: "/usr/bin/yes"),
        arguments: [],
        environment: ["PATH": "/usr/bin:/bin"]
      )
    }

    let processID = try #require(recorder.processID)
    #expect(Self.wasReaped(processID))
  }

  @Test("The deadline kills and reaps a hung process")
  func timeoutCleansUpProcess() async throws {
    let recorder = ProcessRecorder()
    let runner = makeRunner(
      recorder: recorder,
      timeoutMilliseconds: 20
    )

    await #expect(throws: MCPClientSessionError.requestTimedOut) {
      _ = try await runner.run(
        executableURL: URL(fileURLWithPath: "/bin/sleep"),
        arguments: ["60"],
        environment: ["PATH": "/usr/bin:/bin"]
      )
    }

    let processID = try #require(recorder.processID)
    #expect(Self.wasReaped(processID))
  }

  @Test("Timeout kills the owned process group, including a child")
  func timeoutCleansUpProcessGroup() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MCPBoundedProcessRunnerTests-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(
      at: rootURL,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    let childProcessIDURL = rootURL.appendingPathComponent("child-pid")
    let recorder = ProcessRecorder()
    let runner = makeRunner(
      recorder: recorder,
      timeoutMilliseconds: 100
    )

    await #expect(throws: MCPClientSessionError.requestTimedOut) {
      _ = try await runner.run(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [
          "-c",
          "sleep 60 & echo $! > \"$1\"; wait",
          "process-group-fixture",
          childProcessIDURL.path,
        ],
        environment: ["PATH": "/usr/bin:/bin"]
      )
    }

    let leaderProcessID = try #require(recorder.processID)
    #expect(Self.wasReaped(leaderProcessID))
    errno = 0
    let groupProbeResult = Darwin.kill(-leaderProcessID, 0)
    let groupProbeError = errno
    #expect(groupProbeResult == -1)
    #expect(groupProbeError == ESRCH)
    let childProcessIDText = try String(contentsOf: childProcessIDURL, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let childProcessID = try #require(pid_t(childProcessIDText))
    errno = 0
    let childProbeResult = Darwin.kill(childProcessID, 0)
    let childProbeError = errno
    #expect(childProbeResult == -1)
    #expect(childProbeError == ESRCH)
  }

  @Test("Cancellation kills and reaps a running process")
  func cancellationCleansUpProcess() async throws {
    let recorder = ProcessRecorder()
    let runner = makeRunner(recorder: recorder)
    let task = Task {
      try await runner.run(
        executableURL: URL(fileURLWithPath: "/bin/sleep"),
        arguments: ["60"],
        environment: ["PATH": "/usr/bin:/bin"]
      )
    }

    while recorder.processID == nil {
      try await Task.sleep(for: .milliseconds(2))
    }
    task.cancel()

    await #expect(throws: CancellationError.self) {
      _ = try await task.value
    }
    let processID = try #require(recorder.processID)
    #expect(Self.wasReaped(processID))
  }

  @Test("Cancellation during blocking spawn still reaps the eventual child")
  func cancellationDuringSpawnCleansUpProcess() async throws {
    let recorder = ProcessRecorder()
    let runner = MCPBoundedProcessRunner(
      timeoutMilliseconds: 30_000,
      maximumOutputBytes: 64 * 1_024,
      maximumErrorBytes: 64 * 1_024,
      spawnProcess: { configuration, _ in
        usleep(50_000)
        let process = try MCPStdioProcessSpawner.spawn(configuration)
        recorder.record(process.processID)
        return process
      }
    )
    let task = Task {
      try await runner.run(
        executableURL: URL(fileURLWithPath: "/bin/sleep"),
        arguments: ["60"],
        environment: ["PATH": "/usr/bin:/bin"]
      )
    }
    try await Task.sleep(for: .milliseconds(5))
    task.cancel()

    await #expect(throws: CancellationError.self) {
      _ = try await task.value
    }
    let processID = try #require(recorder.processID)
    #expect(Self.wasReaped(processID))
  }

  @Test("Blocking spawn preparation does not bypass the monitor deadline")
  func timeoutAfterSpawnPreparationCleansUpProcess() async throws {
    let recorder = ProcessRecorder()
    let runner = MCPBoundedProcessRunner(
      timeoutMilliseconds: 20,
      maximumOutputBytes: 64 * 1_024,
      maximumErrorBytes: 64 * 1_024,
      spawnProcess: { configuration, _ in
        usleep(50_000)
        let process = try MCPStdioProcessSpawner.spawn(configuration)
        recorder.record(process.processID)
        return process
      }
    )

    await #expect(throws: MCPClientSessionError.requestTimedOut) {
      _ = try await runner.run(
        executableURL: URL(fileURLWithPath: "/usr/bin/true"),
        arguments: [],
        environment: ["PATH": "/usr/bin:/bin"]
      )
    }
    let processID = try #require(recorder.processID)
    #expect(Self.wasReaped(processID))
  }

  @Test("A post-reap cleanup failure never retries a recycled process identifier")
  func cleanupFailureDoesNotRetry() async {
    let cleanupInvocationCount = Mutex(0)
    let runner = MCPBoundedProcessRunner(
      timeoutMilliseconds: 30_000,
      maximumOutputBytes: 64 * 1_024,
      maximumErrorBytes: 64 * 1_024,
      spawnProcess: { configuration, _ in
        try MCPStdioProcessSpawner.spawn(configuration)
      },
      terminateProcess: { processID, _ in
        cleanupInvocationCount.withLock { $0 += 1 }
        MCPStdioProcessSpawner.terminateImmediately(processID)
        throw MCPClientSessionError.connectionClosed
      }
    )

    await #expect(throws: MCPClientSessionError.connectionClosed) {
      _ = try await runner.run(
        executableURL: URL(fileURLWithPath: "/usr/bin/true"),
        arguments: [],
        environment: ["PATH": "/usr/bin:/bin"]
      )
    }
    #expect(cleanupInvocationCount.withLock { $0 } == 1)
  }

  private func makeRunner(
    recorder: ProcessRecorder,
    timeoutMilliseconds: UInt64 = 30_000,
    maximumOutputBytes: Int = 64 * 1_024,
    maximumErrorBytes: Int = 64 * 1_024
  ) -> MCPBoundedProcessRunner {
    MCPBoundedProcessRunner(
      timeoutMilliseconds: timeoutMilliseconds,
      maximumOutputBytes: maximumOutputBytes,
      maximumErrorBytes: maximumErrorBytes,
      spawnProcess: { configuration, reusableExecutableSnapshot in
        let process = try MCPStdioProcessSpawner.spawn(configuration)
        #expect(reusableExecutableSnapshot == nil)
        recorder.record(process.processID)
        return process
      }
    )
  }

  private func compileFixture(
    at executableURL: URL,
    output: String = "snapshot-ready"
  ) throws {
    let sourceURL = executableURL.appendingPathExtension("c")
    let escapedOutput =
      output
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    try Data(
      "#include <stdio.h>\nint main(void) { fputs(\"\(escapedOutput)\", stdout); return 0; }\n"
        .utf8
    ).write(to: sourceURL, options: .withoutOverwriting)
    let process = Process()
    let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["--sdk", "macosx", "clang", sourceURL.path, "-o", executableURL.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errors
    try process.run()
    process.waitUntilExit()
    let errorData = errors.fileHandleForReading.readDataToEndOfFile()
    let errorText = String(decoding: errorData.prefix(4_096), as: UTF8.self)
    try #require(
      process.terminationReason == .exit && process.terminationStatus == 0,
      "Fixture compiler failed: \(errorText)"
    )
  }

  private static func wasReaped(_ processID: pid_t) -> Bool {
    var status = Int32(0)
    errno = 0
    let result = waitpid(processID, &status, WNOHANG)
    return result == -1 && errno == ECHILD
  }

  private final class ProcessRecorder: Sendable {
    private let value = Mutex<pid_t?>(nil)

    var processID: pid_t? {
      value.withLock { $0 }
    }

    func record(_ processID: pid_t) {
      value.withLock { $0 = processID }
    }
  }

  private struct ExecutionPaths: Sendable {
    let configuredPath: String
    let launchPath: String
  }

  private final class ExecutionPathRecorder: Sendable {
    private let value = Mutex<[ExecutionPaths]>([])

    var configuredPath: String? {
      value.withLock { $0.last?.configuredPath }
    }

    var launchPath: String? {
      value.withLock { $0.last?.launchPath }
    }

    var launchPaths: [String] {
      value.withLock { $0.map(\.launchPath) }
    }

    func record(configuredPath: String, launchPath: String) {
      value.withLock {
        $0.append(ExecutionPaths(configuredPath: configuredPath, launchPath: launchPath))
      }
    }
  }
}
