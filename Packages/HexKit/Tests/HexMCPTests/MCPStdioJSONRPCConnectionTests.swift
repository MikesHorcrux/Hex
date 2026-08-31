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
      #"NR == 1 { print "{\"jsonrpc\":\"2.0\",\"id\":\"server-1\",\"method\":\"roots/list\",\"params\":{}}"; fflush(); next } NR == 2 { print "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}"; fflush(); }"#
    let connection = MCPStdioJSONRPCConnection(
      configuration: try configuration(program: program)
    )
    try await connection.connect()
    defer { Task { await connection.disconnect() } }

    let response = try await connection.request(
      method: "test/request",
      params: .object([:])
    )

    #expect(response == .object(["ok": .boolean(true)]))
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
}
