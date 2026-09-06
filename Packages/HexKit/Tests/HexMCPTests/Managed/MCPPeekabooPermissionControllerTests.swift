import Darwin
import Foundation
import Synchronization
import Testing

@testable import HexMCP

@Suite("Peekaboo permission controller")
struct MCPPeekabooPermissionControllerTests {
  @Test("Status preserves a partial grant and accepts empty stderr")
  func reportsPartialGrant() async throws {
    let fixture = try makeLayoutFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let recorder = InvocationRecorder(responses: [
      .output(Self.statusJSON(accessibility: true, screenRecording: false))
    ])
    let controller = try makeController(layout: fixture.layout, recorder: recorder)

    let status = try await controller.status()

    #expect(status.accessibilityGranted)
    #expect(!status.screenRecordingGranted)
    #expect(!status.isGranted)
    #expect(
      recorder.arguments == [
        ["permissions", "status", "--json", "--no-remote"]
      ])
  }

  @Test("Request asks for both permissions before reading final status")
  func requestsBothPermissions() async throws {
    let fixture = try makeLayoutFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let recorder = InvocationRecorder(responses: [
      .output(#"{"success":true,"data":{"granted":false}}"#),
      .output(#"{"success":true,"data":{"granted":true}}"#),
      .output(Self.statusJSON(accessibility: true, screenRecording: true)),
    ])
    let controller = try makeController(layout: fixture.layout, recorder: recorder)

    let status = try await controller.request()

    #expect(status.isGranted)
    #expect(
      recorder.arguments == [
        ["permissions", "request", "accessibility", "--json", "--no-remote"],
        ["permissions", "request", "screen-recording", "--json", "--no-remote"],
        ["permissions", "status", "--json", "--no-remote"],
      ])
  }

  @Test("Malformed status JSON is rejected")
  func rejectsMalformedJSON() async throws {
    let fixture = try makeLayoutFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let recorder = InvocationRecorder(responses: [.output("not-json")])
    let controller = try makeController(layout: fixture.layout, recorder: recorder)

    await #expect(throws: MCPClientSessionError.protocolViolation) {
      _ = try await controller.status()
    }
  }

  @Test("A nonzero permission command is rejected")
  func rejectsNonzeroExit() async throws {
    let fixture = try makeLayoutFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let recorder = InvocationRecorder(responses: [.failure])
    let controller = try makeController(layout: fixture.layout, recorder: recorder)

    await #expect(throws: MCPClientSessionError.connectionClosed) {
      _ = try await controller.status()
    }
  }

  @Test("Oversized permission output is rejected")
  func rejectsOversizedOutput() async throws {
    let fixture = try makeLayoutFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let recorder = InvocationRecorder(responses: [
      .output(String(repeating: "A", count: 1_025))
    ])
    let controller = try makeController(
      layout: fixture.layout,
      recorder: recorder,
      maximumOutputBytes: 1_024
    )

    await #expect(throws: MCPClientSessionError.limitExceeded) {
      _ = try await controller.status()
    }
  }

  @Test("Oversized permission error output is rejected")
  func rejectsOversizedErrorOutput() async throws {
    let fixture = try makeLayoutFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let recorder = InvocationRecorder(responses: [
      .error(String(repeating: "E", count: 1_025))
    ])
    let controller = try makeController(
      layout: fixture.layout,
      recorder: recorder,
      maximumErrorBytes: 1_024
    )

    await #expect(throws: MCPClientSessionError.limitExceeded) {
      _ = try await controller.status()
    }
  }

  @Test("Timeout kills and reaps the permission process group")
  func timeoutCleansUpProcess() async throws {
    let fixture = try makeLayoutFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let recorder = InvocationRecorder(responses: [.hang])
    let controller = try makeController(
      layout: fixture.layout,
      recorder: recorder,
      timeoutMilliseconds: 20
    )

    await #expect(throws: MCPClientSessionError.requestTimedOut) {
      _ = try await controller.status()
    }
    let processID = try #require(recorder.firstProcessID)
    #expect(Self.wasReaped(processID))
  }

  @Test("Cancellation kills and reaps the permission process group")
  func cancellationCleansUpProcess() async throws {
    let fixture = try makeLayoutFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let recorder = InvocationRecorder(responses: [.hang])
    let controller = try makeController(layout: fixture.layout, recorder: recorder)
    let task = Task { try await controller.status() }

    while recorder.firstProcessID == nil {
      try await Task.sleep(for: .milliseconds(2))
    }
    task.cancel()

    await #expect(throws: CancellationError.self) {
      _ = try await task.value
    }
    let processID = try #require(recorder.firstProcessID)
    #expect(Self.wasReaped(processID))
  }

  private func makeController(
    layout: MCPManagedToolLayout,
    recorder: InvocationRecorder,
    timeoutMilliseconds: UInt64 = 30_000,
    maximumOutputBytes: Int = 64 * 1_024,
    maximumErrorBytes: Int = 64 * 1_024
  ) throws -> MCPPeekabooPermissionController {
    try MCPPeekabooPermissionController(
      layout: layout,
      sourceEnvironment: ["PATH": "/usr/bin:/bin"],
      timeoutMilliseconds: timeoutMilliseconds,
      maximumOutputBytes: maximumOutputBytes,
      maximumErrorBytes: maximumErrorBytes,
      spawnProcess: { configuration in
        let response = try recorder.next(arguments: configuration.arguments)
        let spawned = try Self.spawn(response)
        recorder.record(processID: spawned.processID)
        return spawned
      }
    )
  }

  private func makeLayoutFixture() throws -> (root: URL, layout: MCPManagedToolLayout) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hex-peekaboo-permissions-\(UUID().uuidString)",
      isDirectory: true
    )
    let layout = try MCPManagedToolLayout(rootURL: root)
    try FileManager.default.createDirectory(
      at: layout.peekabooExecutableURL.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "/usr/bin/true"),
      to: layout.peekabooExecutableURL
    )
    try Data("\(MCPManagedToolLayout.peekabooVersion)\n".utf8).write(
      to: layout.peekabooVersionFileURL,
      options: .withoutOverwriting
    )
    return (root, layout)
  }

  private static func spawn(_ response: FixtureResponse) throws -> MCPSpawnedProcess {
    let executableURL: URL
    let arguments: [String]
    switch response {
    case .output(let output):
      executableURL = URL(fileURLWithPath: "/usr/bin/printf")
      arguments = ["%s", output]
    case .error(let output):
      executableURL = URL(fileURLWithPath: "/bin/sh")
      arguments = ["-c", #"/usr/bin/printf %s "$1" >&2"#, "permission-fixture", output]
    case .failure:
      executableURL = URL(fileURLWithPath: "/usr/bin/false")
      arguments = []
    case .hang:
      executableURL = URL(fileURLWithPath: "/bin/sleep")
      arguments = ["60"]
    }
    let configuration = try MCPServerConfiguration(
      serverID: "permission-fixture",
      executableURL: executableURL,
      arguments: arguments,
      workingDirectory: URL(fileURLWithPath: "/"),
      environment: ["PATH": "/usr/bin:/bin"],
      requestTimeoutMilliseconds: 30_000,
      shutdownGraceMilliseconds: 50,
      maximumMessageBytes: 2 * 1_024,
      maximumStderrBytes: 1_024
    )
    return try MCPStdioProcessSpawner.spawn(configuration)
  }

  private static func statusJSON(
    accessibility: Bool,
    screenRecording: Bool
  ) -> String {
    """
    {"success":true,"data":{"permissions":[
      {"name":"Accessibility","isGranted":\(accessibility)},
      {"name":"Screen Recording","isGranted":\(screenRecording)}
    ]}}
    """
  }

  private static func wasReaped(_ processID: pid_t) -> Bool {
    var status = Int32(0)
    errno = 0
    let result = waitpid(processID, &status, WNOHANG)
    return result == -1 && errno == ECHILD
  }

  private enum FixtureResponse: Sendable {
    case output(String)
    case error(String)
    case failure
    case hang
  }

  private struct InvocationState: Sendable {
    var responses: [FixtureResponse]
    var arguments: [[String]] = []
    var processIDs: [pid_t] = []
  }

  private final class InvocationRecorder: Sendable {
    private let state: Mutex<InvocationState>

    init(responses: [FixtureResponse]) {
      state = Mutex(InvocationState(responses: responses))
    }

    var arguments: [[String]] {
      state.withLock { $0.arguments }
    }

    var firstProcessID: pid_t? {
      state.withLock { $0.processIDs.first }
    }

    func next(arguments: [String]) throws -> FixtureResponse {
      try state.withLock { state in
        state.arguments.append(arguments)
        guard !state.responses.isEmpty else {
          throw MCPClientSessionError.protocolViolation
        }
        return state.responses.removeFirst()
      }
    }

    func record(processID: pid_t) {
      state.withLock { $0.processIDs.append(processID) }
    }
  }
}
