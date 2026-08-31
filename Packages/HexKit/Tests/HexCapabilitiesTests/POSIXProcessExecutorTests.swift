import Darwin
import Foundation
import HexCapabilities
import Testing

@Suite("POSIX process executor")
struct POSIXProcessExecutorTests {
  @Test
  func runsWithoutAShellInTheSelectedWorkingDirectory() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "hex-process-executor-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executor = POSIXProcessExecutor()

    let result = try await executor.execute(
      ProcessExecutionRequest(
        executable: URL(fileURLWithPath: "/bin/pwd"),
        arguments: [],
        workingDirectory: directory,
        timeoutSeconds: 5
      )
    )

    #expect(result.termination == .exited(code: 0))
    let outputPath = String(decoding: result.output, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(
      URL(fileURLWithPath: outputPath).standardizedFileURL.resolvingSymlinksInPath()
        == directory.standardizedFileURL.resolvingSymlinksInPath()
    )
  }

  @Test
  func capturesStdoutAndStderrAndReportsTheExitCode() async throws {
    let executor = POSIXProcessExecutor()

    let result = try await executor.execute(
      ProcessExecutionRequest(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "printf stdout; printf stderr >&2; exit 7"],
        workingDirectory: URL(fileURLWithPath: "/private/tmp"),
        timeoutSeconds: 5
      )
    )

    #expect(result.termination == .exited(code: 7))
    let output = String(decoding: result.output, as: UTF8.self)
    #expect(output.contains("stdout"))
    #expect(output.contains("stderr"))
  }

  @Test
  func terminatesOnOutputOverflowAndTimeout() async throws {
    let configuration = try ProcessExecutionConfiguration(
      maximumOutputBytes: 1_024,
      maximumTimeoutSeconds: 5,
      pollingIntervalMilliseconds: 5
    )
    let executor = POSIXProcessExecutor(configuration: configuration)
    let directory = URL(fileURLWithPath: "/private/tmp")

    let overflow = try await executor.execute(
      ProcessExecutionRequest(
        executable: URL(fileURLWithPath: "/usr/bin/yes"),
        arguments: [],
        workingDirectory: directory,
        timeoutSeconds: 5
      )
    )
    let timedOut = try await executor.execute(
      ProcessExecutionRequest(
        executable: URL(fileURLWithPath: "/bin/sleep"),
        arguments: ["5"],
        workingDirectory: directory,
        timeoutSeconds: 1
      )
    )

    #expect(overflow.termination == .outputLimitExceeded)
    #expect(overflow.output.count == 1_024)
    #expect(timedOut.termination == .timedOut)
  }

  @Test
  func cancellationKillsTheProcessAndPropagatesCancellation() async throws {
    let executor = POSIXProcessExecutor()
    let task = Task {
      try await executor.execute(
        ProcessExecutionRequest(
          executable: URL(fileURLWithPath: "/bin/sleep"),
          arguments: ["5"],
          workingDirectory: URL(fileURLWithPath: "/private/tmp"),
          timeoutSeconds: 10
        )
      )
    }

    try await Task.sleep(for: .milliseconds(30))
    task.cancel()

    await #expect(throws: CancellationError.self) {
      _ = try await task.value
    }
  }

  @Test
  func concurrentExecutionsKeepProcessOutputIsolated() async throws {
    let executor = POSIXProcessExecutor()
    let results = try await withThrowingTaskGroup(
      of: (Int, ProcessExecutionResult).self,
      returning: [Int: ProcessExecutionResult].self
    ) { group in
      for index in 0..<32 {
        group.addTask {
          let result = try await executor.execute(
            ProcessExecutionRequest(
              executable: URL(fileURLWithPath: "/usr/bin/printf"),
              arguments: ["process-\(index)"],
              workingDirectory: URL(fileURLWithPath: "/private/tmp"),
              timeoutSeconds: 5
            )
          )
          return (index, result)
        }
      }
      var values: [Int: ProcessExecutionResult] = [:]
      for try await (index, result) in group {
        values[index] = result
      }
      return values
    }

    #expect(results.count == 32)
    for index in 0..<32 {
      #expect(results[index]?.termination == .exited(code: 0))
      #expect(
        results[index].map { String(decoding: $0.output, as: UTF8.self) } == "process-\(index)")
    }
  }

  @Test
  func timeoutKillsDescendantsAfterTheProcessGroupLeaderExits() async throws {
    let executor = POSIXProcessExecutor()

    let result = try await executor.execute(
      ProcessExecutionRequest(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "sleep 10 & echo $!"],
        workingDirectory: URL(fileURLWithPath: "/private/tmp"),
        timeoutSeconds: 1
      )
    )
    let output = String(decoding: result.output, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let childProcessID = pid_t(output) else {
      Issue.record("Expected the child process identifier.")
      return
    }
    defer { _ = Darwin.kill(childProcessID, SIGKILL) }

    #expect(result.termination == .timedOut)
    for _ in 0..<100 where Darwin.kill(childProcessID, 0) == 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
    errno = 0
    let probe = Darwin.kill(childProcessID, 0)
    #expect(probe < 0)
    #expect(errno == ESRCH)
  }
}
