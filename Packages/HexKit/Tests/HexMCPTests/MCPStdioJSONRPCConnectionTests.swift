import Darwin
import Foundation
import HexCore
import Testing

@testable import HexMCP

@Suite("MCP stdio JSON-RPC connection", .serialized)
struct MCPStdioJSONRPCConnectionTests {
  @Test("Does not inherit unrelated parent file descriptors")
  func doesNotInheritUnrelatedDescriptors() async throws {
    let sourceDescriptor = Darwin.open("/dev/null", O_RDONLY)
    #expect(sourceDescriptor >= 0)
    defer {
      if sourceDescriptor >= 0 { Darwin.close(sourceDescriptor) }
    }
    let inheritedCandidate = fcntl(sourceDescriptor, F_DUPFD, 200)
    #expect(inheritedCandidate >= 200)
    defer {
      if inheritedCandidate >= 0 { Darwin.close(inheritedCandidate) }
    }
    #expect(fcntl(inheritedCandidate, F_SETFD, 0) == 0)
    let program =
      #"BEGIN { inherited = (system("test -e /dev/fd/\#(inheritedCandidate)") == 0 ? "leaked" : "closed") } { print "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"state\":\"" inherited "\"}}"; fflush(); exit }"#
    let connection = MCPStdioJSONRPCConnection(
      configuration: try configuration(program: program)
    )

    try await connection.connect()
    let response = try await connection.request(method: "fixture", params: .object([:]))

    #expect(response.mcpObject?["state"] == .string("closed"))
    await connection.disconnect()
  }

  @Test("Round trips a bounded response through a real child process")
  func roundTripsResponse() async throws {
    let connection = MCPStdioJSONRPCConnection(
      configuration: try configuration(
        program: #"{ print "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}"; fflush(); }"#
      )
    )
    try await connection.connect()
    defer { Task { await connection.disconnect() } }

    let response = try await connection.request(
      method: "test/echo",
      params: .object(["value": .string("hello")])
    )

    #expect(response == .object(["ok": .boolean(true)]))
  }

  @Test("Answers unsupported server requests before accepting the matching response")
  func answersUnsupportedServerRequests() async throws {
    let program =
      #"NR == 1 { print "{\"jsonrpc\":\"2.0\",\"id\":\"server-1\",\"method\":\"roots/list\",\"params\":{}}"; fflush(); next } NR == 2 { status = index($0, "\"code\":-32601") ? "method-not-found" : "unexpected"; print "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"reply\":\"" status "\"}}"; fflush(); }"#
    let connection = MCPStdioJSONRPCConnection(
      configuration: try configuration(program: program)
    )
    try await connection.connect()
    defer { Task { await connection.disconnect() } }

    let response = try await connection.request(
      method: "test/request",
      params: .object([:])
    )

    #expect(response == .object(["reply": .string("method-not-found")]))
  }

  @Test("Replies to a peer ping with an empty result object")
  func repliesToPeerPing() async throws {
    let program =
      #"NR == 1 { print "{\"jsonrpc\":\"2.0\",\"id\":\"server-ping\",\"method\":\"ping\"}"; fflush(); next } NR == 2 { status = index($0, "\"id\":\"server-ping\"") && index($0, "\"result\":{}") ? "empty-result" : "unexpected"; print "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"reply\":\"" status "\"}}"; fflush(); }"#
    let connection = MCPStdioJSONRPCConnection(
      configuration: try configuration(program: program)
    )
    try await connection.connect()
    defer { Task { await connection.disconnect() } }

    let response = try await connection.request(
      method: "test/ping",
      params: .object([:])
    )

    #expect(response == .object(["reply": .string("empty-result")]))
  }

  @Test("Rejects canonical duplicate response members")
  func rejectsCanonicalDuplicateMembers() async throws {
    let connection = MCPStdioJSONRPCConnection(
      configuration: try configuration(
        program:
          #"{ print "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true,\"\\u006fk\":false}}"; fflush(); }"#
      )
    )
    try await connection.connect()

    await #expect(throws: MCPClientSessionError.protocolViolation) {
      try await connection.request(method: "test/duplicate", params: .object([:]))
    }
    await connection.disconnect()
  }

  @Test("Times out a silent server and closes its process group")
  func timesOutSilentServer() async throws {
    let connection = MCPStdioJSONRPCConnection(
      configuration: try configuration(
        program: #"{ while (1) { } }"#,
        requestTimeoutMilliseconds: 50
      )
    )
    try await connection.connect()

    await #expect(throws: MCPClientSessionError.requestTimedOut) {
      try await connection.request(method: "test/timeout", params: .object([:]))
    }
    await connection.disconnect()
  }

  @Test("Reconnects cleanly across process and descriptor generations")
  func reconnectsAcrossGenerations() async throws {
    let connection = MCPStdioJSONRPCConnection(
      configuration: try configuration(
        program: #"{ print "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}"; fflush(); }"#
      )
    )

    for _ in 0..<10 {
      try await connection.connect()
      let response = try await connection.request(
        method: "test/reconnect",
        params: .object([:])
      )
      #expect(response == .object(["ok": .boolean(true)]))
      await connection.disconnect()
    }
  }

  @Test("Reentrant shutdown shares completion and cannot clobber a replacement")
  func reentrantShutdownCannotClobberReplacement() async throws {
    for _ in 0..<20 {
      let configuration = try catConfiguration()
      let terminator = GatedProcessTerminator()
      let connection = MCPStdioJSONRPCConnection(
        configuration: configuration,
        terminateProcess: { spawned in
          await terminator.terminate(
            spawned,
            shutdownGraceMilliseconds: configuration.shutdownGraceMilliseconds
          )
        }
      )
      try await connection.connect()
      let encodedFirstProcess = await connection.process
      let firstProcess = try #require(encodedFirstProcess)

      let encodedFirstShutdown = await connection.beginShutdown(
        error: MCPClientSessionError.connectionClosed
      )
      let firstShutdown = try #require(encodedFirstShutdown)
      await terminator.waitUntilFirstTerminationStarts()
      let encodedReentrantShutdown = await connection.beginShutdown(
        error: MCPClientSessionError.connectionClosed
      )
      let reentrantShutdown = try #require(encodedReentrantShutdown)

      #expect(firstShutdown === reentrantShutdown)
      #expect(await terminator.invocationCount() == 1)
      if case .closing = await connection.state {
        // Expected while the shared termination operation is gated.
      } else {
        Issue.record("Shutdown published disconnected before termination completed")
      }

      let reconnect = Task {
        try await connection.connect()
      }
      for _ in 0..<20 {
        await Task.yield()
      }
      #expect(await connection.generation == firstShutdown.generation)
      if case .closing = await connection.state {
        // Reconnect must remain behind the in-flight shutdown.
      } else {
        Issue.record("Reconnect proceeded before shutdown completed")
      }

      await terminator.releaseFirstTermination()
      try await reconnect.value
      let encodedReplacement = await connection.process
      let replacement = try #require(encodedReplacement)

      #expect(await connection.generation == firstShutdown.generation + 1)
      #expect(replacement.processID != firstProcess.processID)
      #expect(Darwin.kill(firstProcess.processID, 0) == -1 && errno == ESRCH)
      #expect(Darwin.kill(replacement.processID, 0) == 0)
      if case .connected = await connection.state {
        // Expected after the replacement process is installed.
      } else {
        Issue.record("Replacement did not remain connected")
      }

      await connection.finishShutdown(
        id: firstShutdown.id,
        generation: firstShutdown.generation
      )
      #expect(await connection.process?.processID == replacement.processID)
      if case .connected = await connection.state {
        // A stale finalizer must not publish disconnected.
      } else {
        Issue.record("A stale finalizer clobbered the replacement")
      }

      await connection.disconnect()
      #expect(await terminator.invocationCount() == 2)
    }
  }

  @Test("Serializes concurrent writes and correlates every response")
  func serializesConcurrentRequests() async throws {
    let program =
      #"{ if (match($0, /\"id\":[0-9]+/)) { id = substr($0, RSTART + 5, RLENGTH - 5); print "{\"jsonrpc\":\"2.0\",\"id\":" id ",\"result\":{\"ok\":true}}"; fflush(); } }"#
    let connection = MCPStdioJSONRPCConnection(
      configuration: try configuration(program: program)
    )
    try await connection.connect()

    try await withThrowingTaskGroup(of: JSONValue.self) { group in
      for index in 0..<32 {
        group.addTask {
          try await connection.request(
            method: "test/concurrent",
            params: .object(["index": .integer(Int64(index))])
          )
        }
      }
      var count = 0
      for try await response in group {
        #expect(response == .object(["ok": .boolean(true)]))
        count += 1
      }
      #expect(count == 32)
    }
    await connection.disconnect()
  }

  @Test("Cancellation terminates the in-flight server process")
  func cancellationTerminatesProcess() async throws {
    let connection = MCPStdioJSONRPCConnection(
      configuration: try configuration(
        program: #"{ while (1) { } }"#,
        requestTimeoutMilliseconds: 2_000
      )
    )
    try await connection.connect()
    let task = Task {
      try await connection.request(method: "test/cancel", params: .object([:]))
    }
    try await Task.sleep(for: .milliseconds(20))
    task.cancel()

    await #expect(throws: CancellationError.self) {
      try await task.value
    }
    await connection.disconnect()
  }

  @Test("Rejects an oversized unterminated stdout frame")
  func rejectsOversizedUnterminatedFrame() async throws {
    let connection = MCPStdioJSONRPCConnection(
      configuration: try configuration(
        program: #"{ for (i = 0; i < 2048; i++) printf "a"; fflush(); }"#
      )
    )
    try await connection.connect()

    await #expect(throws: MCPClientSessionError.limitExceeded) {
      try await connection.request(method: "test/oversized", params: .object([:]))
    }
    await connection.disconnect()
  }

  @Test("Drains stderr without publishing or retaining it as protocol data")
  func drainsStderr() async throws {
    let program =
      #"{ for (i = 0; i < 65536; i++) printf "e" > "/dev/stderr"; fflush("/dev/stderr"); print "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}"; fflush(); }"#
    let connection = MCPStdioJSONRPCConnection(
      configuration: try configuration(program: program)
    )
    try await connection.connect()

    let response = try await connection.request(
      method: "test/stderr",
      params: .object([:])
    )
    #expect(response == .object(["ok": .boolean(true)]))
    await connection.disconnect()
  }

  private func configuration(
    program: String,
    requestTimeoutMilliseconds: UInt64 = 2_000
  ) throws -> MCPServerConfiguration {
    try MCPServerConfiguration(
      serverID: "fixture",
      executableURL: URL(fileURLWithPath: "/usr/bin/awk"),
      arguments: [program],
      workingDirectory: URL(fileURLWithPath: "/"),
      environment: ["PATH": "/usr/bin:/bin"],
      requestTimeoutMilliseconds: requestTimeoutMilliseconds,
      shutdownGraceMilliseconds: 50,
      maximumMessageBytes: 1_024,
      maximumStderrBytes: 1_024
    )
  }

  private func catConfiguration() throws -> MCPServerConfiguration {
    try MCPServerConfiguration(
      serverID: "fixture",
      executableURL: URL(fileURLWithPath: "/bin/cat"),
      arguments: [],
      workingDirectory: URL(fileURLWithPath: "/"),
      environment: ["PATH": "/usr/bin:/bin"],
      requestTimeoutMilliseconds: 2_000,
      shutdownGraceMilliseconds: 50,
      maximumMessageBytes: 1_024,
      maximumStderrBytes: 1_024
    )
  }

  actor GatedProcessTerminator {
    private var firstTerminationStarted = false
    private var firstTerminationReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var invocations = 0

    func terminate(
      _ spawned: MCPSpawnedProcess,
      shutdownGraceMilliseconds: UInt64
    ) async {
      invocations += 1
      if invocations == 1 {
        firstTerminationStarted = true
        let waiters = startWaiters
        startWaiters = []
        for waiter in waiters {
          waiter.resume()
        }
        if !firstTerminationReleased {
          await withCheckedContinuation { continuation in
            releaseWaiter = continuation
          }
        }
      }
      await MCPStdioJSONRPCConnection.terminate(
        spawned,
        shutdownGraceMilliseconds: shutdownGraceMilliseconds
      )
    }

    func waitUntilFirstTerminationStarts() async {
      if firstTerminationStarted { return }
      await withCheckedContinuation { continuation in
        startWaiters.append(continuation)
      }
    }

    func releaseFirstTermination() {
      firstTerminationReleased = true
      releaseWaiter?.resume()
      releaseWaiter = nil
    }

    func invocationCount() -> Int {
      invocations
    }
  }
}
