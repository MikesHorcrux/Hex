import Foundation
import Testing

@testable import Hex

@Suite("Managed tool process runner")
struct HexManagedToolProcessRunnerTests {
  @Test
  func archiveExecutableUsesCanonicalSystemBinary() async throws {
    let runner = HexManagedToolProcessRunner()
    let result = try await runner.run(
      executableURL: URL(fileURLWithPath: "/usr/bin/bsdtar"), arguments: ["--version"])
    #expect(result.status == 0)
    #expect(String(decoding: result.standardOutput, as: UTF8.self).contains("bsdtar"))
    await #expect(throws: HexManagedToolInstallerError.self) {
      _ = try await runner.run(
        executableURL: URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["--version"])
    }
  }

  @Test
  func successfulCommandAcceptsEmptyStandardError() async throws {
    let result = try await HexManagedToolProcessRunner().run(
      executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
      arguments: ["%s", "ready\n"]
    )

    #expect(result.status == 0)
    #expect(String(data: result.standardOutput, encoding: .utf8) == "ready\n")
    #expect(result.standardError.isEmpty)
  }

  @Test
  func outputLimitFailsClosed() async {
    let runner = HexManagedToolProcessRunner(maximumOutputBytes: 1_024)

    await #expect(throws: HexManagedToolInstallerError.self) {
      _ = try await runner.run(
        executableURL: URL(fileURLWithPath: "/usr/bin/yes"),
        arguments: []
      )
    }
  }

  @Test
  func managedToolEnvironmentIsAccepted() async throws {
    let result = try await HexManagedToolProcessRunner().run(
      executableURL: URL(fileURLWithPath: "/usr/bin/true"),
      arguments: [],
      environment: [
        "NPM_CONFIG_CACHE": "/private/tmp/hex-npm-cache",
        "PATH": "/usr/bin:/bin",
        "PLAYWRIGHT_BROWSERS_PATH": "/private/tmp/hex-browsers",
        "PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD": "1",
      ]
    )

    #expect(result.status == 0)
    #expect(result.standardOutput.isEmpty)
    #expect(result.standardError.isEmpty)
  }

  @Test
  func cancellationRemainsCancellation() async throws {
    let runner = HexManagedToolProcessRunner()
    let task = Task {
      try await runner.run(
        executableURL: URL(fileURLWithPath: "/bin/sleep"),
        arguments: ["60"]
      )
    }
    try await Task.sleep(for: .milliseconds(20))
    task.cancel()

    await #expect(throws: CancellationError.self) {
      _ = try await task.value
    }
  }
}
