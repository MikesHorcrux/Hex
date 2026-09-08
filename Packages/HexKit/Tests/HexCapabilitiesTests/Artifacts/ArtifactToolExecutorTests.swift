import Foundation
import HexCore
import Testing

@testable import HexCapabilities

@Suite("Bounded conversation artifact tools")
struct ArtifactToolExecutorTests {
  @Test
  func authorizesAnExactPriorTurnReferenceWithoutReadingItsBytes() async throws {
    let bytes = Data("earlier output".utf8)
    let reference = reference(bytes)
    let reader = Reader(bytes: bytes)
    let executor = try ArtifactToolExecutor(reader: reader)
    let context = ToolExecutionContext(runID: AgentRunID(), artifacts: [reference])
    let call = call("artifact_read", reference: reference)

    let authorization = try await executor.authorizationRequest(for: call, in: context)
    #expect(authorization.runID == context.runID)
    #expect(authorization.toolCallID == call.id)
    #expect(authorization.capability == CapabilityID(rawValue: "artifact.read"))
    #expect(
      authorization.resource == "artifact:\(reference.id.uuidString):sha256:\(reference.sha256)")
    #expect(authorization.details["source_run_id"] == .string(reference.runID.rawValue.uuidString))
    #expect(await reader.readCount == 0)
    #expect(
      try await executor.availableTools().map(\.name)
        == ["artifact_list", "artifact_read", "artifact_search"])

    let result = try await executor.execute(call, in: context)
    #expect(result.status == .success)
    #expect(try output(result)["content"] == .string("earlier output"))
    #expect(await reader.references == [reference])
    #expect(reference.runID != context.runID)
  }

  @Test
  func listsOnlyTheRequestedCatalogPageWithoutReadingOutput() async throws {
    let reader = Reader(bytes: Data())
    let executor = try ArtifactToolExecutor(reader: reader)
    let references = (0..<23).map { reference(Data("output-\($0)".utf8)) }
    let context = ToolExecutionContext(runID: AgentRunID(), artifacts: references)
    let call = ToolCall(
      name: "artifact_list", arguments: ["offset": .integer(20), "limit": .integer(10)])
    let authorization = try await executor.authorizationRequest(for: call, in: context)
    #expect(authorization.capability == CapabilityID(rawValue: "artifact.read"))
    let values = try output(await executor.execute(call, in: context))
    guard case .array(let entries) = values["artifacts"] else {
      Issue.record("Expected a catalog page")
      return
    }
    #expect(entries.count == 3)
    #expect(values["total"] == .integer(23))
    #expect(values["next_offset"] == .null)
    #expect(await reader.readCount == 0)
  }

  @Test
  func unknownIDsAndConflictingReferencesNeverReachTheReaderOrAuthorization() async throws {
    let bytes = Data("private".utf8)
    let reference = reference(bytes)
    let reader = Reader(bytes: bytes)
    let executor = try ArtifactToolExecutor(reader: reader)
    let call = call("artifact_read", reference: reference)
    let empty = ToolExecutionContext(runID: AgentRunID())
    await #expect(throws: ArtifactToolError.unknownArtifact) {
      _ = try await executor.authorizationRequest(for: call, in: empty)
    }
    #expect(
      try output(await executor.execute(call, in: empty))["error"]
        == .string("artifact_not_in_conversation"))

    let conflicting = ArtifactReference(
      id: reference.id, runID: reference.runID, mediaType: reference.mediaType,
      byteCount: reference.byteCount, sha256: String(repeating: "b", count: 64), isComplete: true)
    let context = ToolExecutionContext(runID: AgentRunID(), artifacts: [reference, conflicting])
    await #expect(throws: ArtifactToolError.invalidReference) {
      _ = try await executor.authorizationRequest(for: call, in: context)
    }
    #expect(
      try output(await executor.execute(call, in: context))["error"]
        == .string("invalid_artifact_reference"))
    #expect(await reader.readCount == 0)
  }

  @Test
  func readsExactByteSlicesWithoutReplacingSplitUTF8AndSeparatesEOFfromCompleteness() async throws {
    let bytes = Data("A🐑B".utf8)
    let reference = reference(bytes, isComplete: false)
    let reader = Reader(bytes: bytes)
    let executor = try ArtifactToolExecutor(reader: reader)
    let context = ToolExecutionContext(runID: AgentRunID(), artifacts: [reference])
    let first = try await executor.execute(
      call(
        "artifact_read", reference: reference,
        arguments: ["offset": .integer(1), "maximum_bytes": .integer(2)]),
      in: context)
    let values = try output(first)
    #expect(values["encoding"] == .string("base64"))
    #expect(values["content"] == .string(bytes.subdata(in: 1..<3).base64EncodedString()))
    #expect(values["next_offset"] == .integer(3))
    #expect(values["eof"] == .boolean(false))
    let final = try await executor.execute(
      call("artifact_read", reference: reference, arguments: ["offset": .integer(3)]), in: context)
    #expect(try output(final)["eof"] == .boolean(true))
    #expect(try output(final)["is_complete"] == .boolean(false))
    #expect(try output(final)["full_byte_count"] == .integer(Int64(bytes.count)))
  }

  @Test
  func boundedSearchOverlapsWindowsSoSplitLiteralIsNotLost() async throws {
    let bytes = Data("1234needle-tail".utf8)
    let reference = reference(bytes)
    let reader = Reader(bytes: bytes)
    let executor = try ArtifactToolExecutor(reader: reader)
    let context = ToolExecutionContext(runID: AgentRunID(), artifacts: [reference])
    let arguments: [String: JSONValue] = [
      "query": .string("needle"), "maximum_scan_bytes": .integer(8),
    ]
    let first = try await executor.execute(
      call("artifact_search", reference: reference, arguments: arguments), in: context)
    let firstOutput = try output(first)
    #expect(firstOutput["matches"] == .array([]))
    #expect(firstOutput["next_scan_offset"] == .integer(3))
    #expect(firstOutput["search_complete"] == .boolean(false))
    let second = try await executor.execute(
      call(
        "artifact_search", reference: reference,
        arguments: arguments.merging(["offset": .integer(3)]) { _, new in new }),
      in: context)
    let secondOutput = try output(second)
    guard case .array(let matches) = secondOutput["matches"],
      case .object(let match) = matches.first
    else {
      Issue.record("Expected one literal match")
      return
    }
    #expect(matches.count == 1)
    #expect(match["offset"] == .integer(4))
    #expect(match["length_bytes"] == .integer(6))
    #expect(secondOutput["next_scan_offset"] == .integer(6))
    #expect(await reader.maximumRequests == [8, 8])
  }

  @Test
  func matchLimitSupportsOverlappingMatchesAndLabelsBinaryWindows() async throws {
    let bytes = Data([0]) + Data("aaaa".utf8)
    let reference = reference(bytes)
    let reader = Reader(bytes: bytes)
    let executor = try ArtifactToolExecutor(reader: reader)
    let context = ToolExecutionContext(runID: AgentRunID(), artifacts: [reference])
    let result = try await executor.execute(
      call(
        "artifact_search", reference: reference,
        arguments: ["query": .string("aa"), "maximum_matches": .integer(1)]), in: context)
    let values = try output(result)
    #expect(values["next_scan_offset"] == .integer(2))
    #expect(values["match_limit_reached"] == .boolean(true))
    #expect(values["reached_eof"] == .boolean(false))
    #expect(values["window_is_binary_or_partial_utf8"] == .boolean(true))
    guard case .array(let matches) = values["matches"], case .object(let match) = matches.first
    else {
      Issue.record("Expected binary-window literal match")
      return
    }
    #expect(match["offset"] == .integer(1))
    #expect(match["encoding"] == .string("base64"))
  }

  @Test
  func invalidBoundsAndArbitraryPathsAreRejectedWithoutReading() async throws {
    let bytes = Data("output".utf8)
    let reference = reference(bytes)
    let reader = Reader(bytes: bytes)
    let executor = try ArtifactToolExecutor(reader: reader)
    let context = ToolExecutionContext(runID: AgentRunID(), artifacts: [reference])
    for arguments: [String: JSONValue] in [
      ["path": .string("/private/output")], ["offset": .integer(-1)],
      ["offset": .integer(7)], ["maximum_bytes": .integer(65_537)],
    ] {
      let result = try await executor.execute(
        call("artifact_read", reference: reference, arguments: arguments), in: context)
      #expect(result.status == .failure)
      #expect(try output(result)["error"] == .string("invalid_arguments"))
    }
    #expect(await reader.readCount == 0)
  }

  @Test(arguments: [Reader.Behavior.wrongOffset, .wrongReference, .oversized, .nonprogressing])
  func rejectsAnInconsistentReaderWithoutReturningUntrustedBytes(_ behavior: Reader.Behavior)
    async throws
  {
    let bytes = Data("output".utf8)
    let reference = reference(bytes)
    let reader = Reader(bytes: bytes, behavior: behavior)
    let executor = try ArtifactToolExecutor(reader: reader)
    let result = try await executor.execute(
      call("artifact_read", reference: reference, arguments: ["maximum_bytes": .integer(2)]),
      in: ToolExecutionContext(runID: AgentRunID(), artifacts: [reference]))
    #expect(result.status == .failure)
    #expect(try output(result) == ["error": .string("inconsistent_artifact_chunk")])
  }

  @Test
  func cancellationNeverBecomesAnArtifactFailureResult() async throws {
    let bytes = Data("output".utf8)
    let reference = reference(bytes)
    let executor = try ArtifactToolExecutor(reader: Reader(bytes: bytes, behavior: .cancelled))
    await #expect(throws: CancellationError.self) {
      _ = try await executor.execute(
        call("artifact_read", reference: reference),
        in: ToolExecutionContext(runID: AgentRunID(), artifacts: [reference]))
    }
  }

  private func reference(_ bytes: Data, isComplete: Bool = true) -> ArtifactReference {
    ArtifactReference(
      id: UUID(), runID: AgentRunID(), mediaType: "text/plain", byteCount: Int64(bytes.count),
      sha256: String(repeating: "a", count: 64), isComplete: isComplete)
  }

  private func call(
    _ name: String, reference: ArtifactReference, arguments: [String: JSONValue] = [:]
  ) -> ToolCall {
    ToolCall(
      name: name,
      arguments: arguments.merging(["artifact_id": .string(reference.id.uuidString)]) { _, new in
        new
      })
  }

  private func output(_ result: ToolResult) throws -> [String: JSONValue] {
    guard case .object(let values) = result.output else { throw FixtureError.notObject }
    return values
  }

  private enum FixtureError: Error { case notObject }

  actor Reader: ArtifactReading {
    enum Behavior: Equatable, Sendable {
      case normal, wrongOffset, wrongReference, oversized, nonprogressing, cancelled
    }
    let bytes: Data
    let behavior: Behavior
    private(set) var readCount = 0
    private(set) var references: [ArtifactReference] = []
    private(set) var maximumRequests: [Int] = []
    init(bytes: Data, behavior: Behavior = .normal) {
      self.bytes = bytes
      self.behavior = behavior
    }
    func read(_ reference: ArtifactReference, offset: Int64, maximumBytes: Int) async throws
      -> ArtifactChunk
    {
      readCount += 1
      references.append(reference)
      maximumRequests.append(maximumBytes)
      if behavior == .cancelled { throw CancellationError() }
      let start = Int(offset)
      let count = behavior == .oversized ? maximumBytes + 1 : maximumBytes
      let end = min(bytes.count, start + count)
      let data = behavior == .nonprogressing ? Data() : bytes.subdata(in: start..<end)
      let chunkReference =
        behavior == .wrongReference
        ? ArtifactReference(
          id: UUID(), runID: reference.runID, mediaType: reference.mediaType,
          byteCount: reference.byteCount,
          sha256: reference.sha256, isComplete: reference.isComplete) : reference
      return ArtifactChunk(
        reference: chunkReference, offset: behavior == .wrongOffset ? offset + 1 : offset,
        data: data, nextOffset: end < bytes.count ? Int64(end) : nil)
    }
  }
}
