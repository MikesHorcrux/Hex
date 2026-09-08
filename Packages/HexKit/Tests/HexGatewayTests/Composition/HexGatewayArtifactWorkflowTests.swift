import CryptoKit
import Foundation
import HexCapabilities
import HexCore
import HexGatewayKit
import HexIPC
import HexPersistence
import Testing

@Suite("Gateway preserved output workflow")
struct HexGatewayArtifactWorkflowTests {
  @Test
  func realProcessOutputBeyondTheOldLimitIsRetrievedByTheModelAndSurvivesReopen() async throws {
    let expected = Data((1...120_000).map { "\($0)\n" }.joined().utf8)
    let fixture = try await runWorkflow(mode: .process)
    #expect(fixture.originalResult.status == .success)
    guard case .object(let output) = fixture.originalResult.output else {
      Issue.record("Expected the real process output preview.")
      return
    }
    #expect(output["termination"] == .string("exited"))
    #expect(output["exit_code"] == .integer(0))
    #expect(
      output["output_bytes"]
        == .integer(Int64(ProcessExecutionConfiguration.standard.maximumOutputBytes)))
    #expect(output["preview_truncated"] == .boolean(true))
    #expect(output["output_complete"] == .boolean(true))
    #expect(output["total_output_bytes"] == .integer(Int64(expected.count)))
    #expect(fixture.reference.byteCount > 512 * 1_024)
    #expect(fixture.reference.mediaType == "application/octet-stream")
    #expect(fixture.savedBytes == expected)
    #expect(fixture.reference.sha256 == digest(expected))
  }

  @Test
  func oversizedStructuredToolOutputIsStoredBeforeTheRuntimeInlineLimit() async throws {
    let fixture = try await runWorkflow(mode: .structured)
    #expect(fixture.reference.byteCount > 2 * 1_024 * 1_024)
    #expect(fixture.reference.mediaType == "application/json")
    #expect(fixture.originalResult.status == .success)
    guard case .object(let output) = fixture.originalResult.output else {
      Issue.record("Expected the runtime's bounded structured-output receipt.")
      return
    }
    #expect(output["stored_tool_result"] == .boolean(true))
    #expect(output["hex_observation_id"] == .string("11111111-2222-3333-4444-555555555555"))
    #expect(output["observation_id"] == .string("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
    #expect(output["hex_observed_pid"] == .integer(42))
    #expect(output["snapshot"] == .string("fixture-snapshot"))
    #expect(output["arbitrary_field"] == nil)
    #expect(output["preview_truncated"] == .boolean(true))
    #expect(try JSONEncoder().encode(fixture.originalResult).count < 32 * 1_024)
    let restored = try JSONDecoder().decode(ToolResult.self, from: fixture.savedBytes)
    #expect(restored == OversizedTool.result(callID: fixture.originalResult.toolCallID))
    #expect(fixture.reference.sha256 == digest(fixture.savedBytes))
  }

  @Test
  func realCaptureQuotaFailureStopsBeforeAnotherProviderRequest() async throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("hex-artifact-attention-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)])
    defer { try? FileManager.default.removeItem(at: directory) }
    let artifactURL = directory.appendingPathComponent("artifacts", isDirectory: true)
    let store = try FileArtifactStore(
      rootURL: artifactURL, maximumArtifactBytes: 16_384, maximumTotalBytes: 32_768)
    let provider = WorkflowProvider(mode: .process)
    let tools = try HostToolExecutor(tools: [
      ProcessRunTool(executor: POSIXProcessExecutor(artifactWriter: store))
    ])
    let journalConfiguration = SQLiteAgentEventJournalConfiguration(
      databaseURL: directory.appendingPathComponent("journal.sqlite"))
    let gatewayConfiguration = try #require(
      GatewayConfiguration(
        maximumWireBytes: 262_144, maximumRetainedRecordsPerRun: 64,
        subscriberBufferCapacity: 64))
    let composition = try await HexGatewayComposition.open(
      configuration: HexGatewayCompositionConfiguration(
        journalConfiguration: journalConfiguration, inferenceProvider: provider,
        toolExecutor: tools, authorizationProvider: GatewayTestAuthorizationProvider(),
        gatewayConfiguration: gatewayConfiguration, artifactWriter: store, artifactReader: store))
    let client = HexGatewayClient(
      transport: composition.transport, configuration: gatewayConfiguration)
    let runID = AgentRunID()
    let records: [AgentEventRecord]
    do {
      _ = try await client.connect()
      let admission = try await client.startRun(
        GatewayStartRunRequest(
          runID: runID, modelID: provider.modelID,
          initialMessages: [
            Message(
              role: .user, content: [.text("Produce output beyond this fixture's disk quota.")])
          ],
          workingDirectory: directory))
      let invocation = try #require(admission.invocationID)
      let stream = try await client.eventRecords(for: runID, invocationID: invocation)
      records = try await collectWithDeadline(stream, client: client)
      try await client.disconnect()
      try await composition.close()
    } catch {
      try? await client.disconnect()
      try? await composition.close()
      throw error
    }
    #expect(await provider.requestCount == 1)
    #expect(
      records.filter {
        if case .toolStarted = $0.event { return true }
        return false
      }.count == 1)
    let finished = try #require(
      records.first {
        if case .toolFinished = $0.event { return true }
        return false
      })
    guard case .toolFinished(let receipt) = finished.event else {
      throw FixtureError.unexpectedToolResult
    }
    #expect(receipt.requiresUserAttention)
    #expect(receipt.status == .failure)
    guard case .object(let output) = receipt.output else { throw FixtureError.unexpectedToolResult }
    #expect(output["termination"] == .string("output_capture_failed"))
    #expect(output["output_capture_error"] == .string("quota_exceeded"))
    let nativeMessage = try #require(
      records.first {
        guard case .messageAppended(let message) = $0.event else { return false }
        return message.role == .tool && message.content == [.toolResult(receipt)]
      })
    let terminal = try #require(records.last)
    guard case .runFailed(let failure) = terminal.event else {
      throw FixtureError.unexpectedToolResult
    }
    #expect(!failure.isRetryable)
    #expect(failure.message.contains("requires your attention"))
    #expect(finished.sequence < nativeMessage.sequence)
    #expect(nativeMessage.sequence < terminal.sequence)
    let reference = try #require(receipt.artifacts.first)
    #expect(!reference.isComplete)
    let reopenedStore = try FileArtifactStore(rootURL: artifactURL)
    let chunk = try await reopenedStore.read(reference, offset: 0, maximumBytes: 65_536)
    #expect(chunk.reference == reference)
    #expect(Int64(chunk.data.count) == reference.byteCount)
    let reopenedJournal = try await SQLiteAgentEventJournal.open(
      configuration: journalConfiguration)
    do {
      #expect(try await reopenedJournal.records(for: runID, after: nil, limit: 128) == records)
      try await reopenedJournal.close()
    } catch {
      try? await reopenedJournal.close()
      throw error
    }
  }

  @Test
  func cancelledProcessJournalsItsReachablePartialArtifactBeforeRunCancelled() async throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("hex-artifact-cancel-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)])
    defer { try? FileManager.default.removeItem(at: directory) }
    let artifactURL = directory.appendingPathComponent("artifacts", isDirectory: true)
    let store = try FileArtifactStore(rootURL: artifactURL)
    let call = ToolCall(
      id: ToolCallID(rawValue: "cancel-process"), name: "process_run",
      arguments: [
        "executable": .string("/bin/sh"),
        "arguments": .array([
          .string("-c"), .string("printf cancellation-marker; exec /bin/sleep 10"),
        ]),
        "timeout_seconds": .integer(10),
      ])
    let provider = GatewayTestInferenceProvider(toolCall: call)
    let tools = try HostToolExecutor(tools: [
      ProcessRunTool(executor: POSIXProcessExecutor(artifactWriter: store))
    ])
    let journalConfiguration = SQLiteAgentEventJournalConfiguration(
      databaseURL: directory.appendingPathComponent("journal.sqlite"))
    let gatewayConfiguration = try #require(
      GatewayConfiguration(
        maximumWireBytes: 262_144, maximumRetainedRecordsPerRun: 64,
        subscriberBufferCapacity: 64))
    let composition = try await HexGatewayComposition.open(
      configuration: HexGatewayCompositionConfiguration(
        journalConfiguration: journalConfiguration, inferenceProvider: provider,
        toolExecutor: tools, authorizationProvider: GatewayTestAuthorizationProvider(),
        gatewayConfiguration: gatewayConfiguration, artifactWriter: store, artifactReader: store))
    let client = HexGatewayClient(
      transport: composition.transport, configuration: gatewayConfiguration)
    let runID = AgentRunID()
    var invocationID: GatewayRunInvocationID?
    var collected: [AgentEventRecord] = []
    do {
      _ = try await client.connect()
      let admission = try await client.startRun(
        GatewayStartRunRequest(
          runID: runID, modelID: provider.modelID,
          initialMessages: [
            Message(role: .user, content: [.text("Start the cancellable process.")])
          ],
          workingDirectory: directory))
      let invocation = try #require(admission.invocationID)
      invocationID = invocation
      let stream = try await client.eventRecords(for: runID, invocationID: invocation)
      // Observe a real write in our temporary store before cancelling. No proxy writer or fake
      // process stands in for the capture boundary. The process also has a hard ten-second limit.
      try await waitForCapturedBytes(in: artifactURL)
      let response = try await client.cancelRun(
        GatewayCancelRunRequest(runID: runID, invocationID: invocation))
      #expect(response.disposition == .requested)
      collected = try await collectWithDeadline(stream, client: client)
      #expect(collected.last?.event == .runCancelled)
      #expect(!collected.contains { $0.event == .runCompleted })
      #expect(
        try await composition.journal.records(for: runID, after: nil, limit: 128) == collected)
      try await client.disconnect()
      try await composition.close()
    } catch {
      if let invocationID {
        _ = try? await client.cancelRun(
          GatewayCancelRunRequest(runID: runID, invocationID: invocationID))
      }
      try? await client.disconnect()
      try? await composition.close()
      throw error
    }
    let finished = try #require(
      collected.first {
        if case .toolFinished = $0.event { return true }
        return false
      })
    let terminal = try #require(collected.last)
    #expect(finished.sequence < terminal.sequence)
    guard case .toolFinished(let receipt) = finished.event,
      case .object(let output) = receipt.output
    else {
      Issue.record("Expected the known cancelled tool receipt before the terminal run event.")
      return
    }
    #expect(receipt.toolCallID == call.id)
    #expect(receipt.status == .failure)
    #expect(!receipt.requiresUserAttention)
    let nativeReceipts = collected.filter {
      guard case .messageAppended(let message) = $0.event else { return false }
      return message.role == .tool && message.content == [.toolResult(receipt)]
    }
    #expect(nativeReceipts.count == 1)
    let nativeReceipt = try #require(nativeReceipts.first)
    #expect(finished.sequence < nativeReceipt.sequence)
    #expect(nativeReceipt.sequence < terminal.sequence)
    #expect(output["termination"] == .string("cancelled"))
    #expect(output["output_complete"] == .boolean(false))
    let reference = try #require(receipt.artifacts.first)
    #expect(!reference.isComplete)
    #expect(reference.runID == runID)
    #expect(reference.toolCallID == call.id)
    let reopenedStore = try FileArtifactStore(rootURL: artifactURL)
    let chunk = try await reopenedStore.read(reference, offset: 0, maximumBytes: 256)
    #expect(chunk.data == Data("cancellation-marker".utf8))
    #expect(chunk.nextOffset == nil)
    let reopenedJournal = try await SQLiteAgentEventJournal.open(
      configuration: journalConfiguration)
    do {
      #expect(try await reopenedJournal.records(for: runID, after: nil, limit: 128) == collected)
      try await reopenedJournal.close()
    } catch {
      try? await reopenedJournal.close()
      throw error
    }
  }

  private func waitForCapturedBytes(in directory: URL) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline {
      try Task.checkCancellation()
      let files = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
      for file in files where file.pathExtension == "blob" {
        if (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0 { return }
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw FixtureError.captureTimedOut
  }

  private func collectWithDeadline(
    _ stream: AsyncThrowingStream<GatewayEventEnvelope, any Error>, client: HexGatewayClient
  ) async throws -> [AgentEventRecord] {
    try await withThrowingTaskGroup(of: [AgentEventRecord].self) { group in
      group.addTask {
        var records: [AgentEventRecord] = []
        for try await envelope in stream {
          records.append(envelope.record)
          try await client.acknowledge(envelope)
        }
        return records
      }
      group.addTask {
        try await Task.sleep(for: .seconds(15))
        throw FixtureError.streamTimedOut
      }
      defer { group.cancelAll() }
      return try #require(try await group.next())
    }
  }

  private func runWorkflow(mode: Mode) async throws -> WorkflowEvidence {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("hex-artifact-workflow-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)])
    defer { try? FileManager.default.removeItem(at: directory) }
    let artifactURL = directory.appendingPathComponent("artifacts", isDirectory: true)
    let store = try FileArtifactStore(rootURL: artifactURL)
    let provider = WorkflowProvider(mode: mode)
    let initialTool: any HostTool
    switch mode {
    case .process:
      initialTool = ProcessRunTool(executor: POSIXProcessExecutor(artifactWriter: store))
    case .structured:
      initialTool = OversizedTool()
    }
    let tools = try HostToolExecutor(tools: [
      initialTool, ArtifactSearchTool(reader: store), ArtifactReadTool(reader: store),
    ])
    let journalConfiguration = SQLiteAgentEventJournalConfiguration(
      databaseURL: directory.appendingPathComponent("journal.sqlite"))
    let gatewayConfiguration = try #require(
      GatewayConfiguration(
        maximumWireBytes: 262_144, maximumRetainedRecordsPerRun: 128,
        subscriberBufferCapacity: 128))
    let composition = try await HexGatewayComposition.open(
      configuration: HexGatewayCompositionConfiguration(
        journalConfiguration: journalConfiguration, inferenceProvider: provider,
        toolExecutor: tools, authorizationProvider: GatewayTestAuthorizationProvider(),
        gatewayConfiguration: gatewayConfiguration, artifactWriter: store, artifactReader: store))
    let client = HexGatewayClient(
      transport: composition.transport, configuration: gatewayConfiguration)
    let runID = AgentRunID()
    let records: [AgentEventRecord]
    do {
      _ = try await client.connect()
      let admission = try await client.startRun(
        GatewayStartRunRequest(
          runID: runID, modelID: provider.modelID,
          initialMessages: [
            Message(
              role: .user,
              content: [.text("Produce the output, find the marker, read it, and finish.")])
          ],
          workingDirectory: directory))
      let invocationID = try #require(admission.invocationID)
      var received: [AgentEventRecord] = []
      let stream = try await client.eventRecords(for: runID, invocationID: invocationID)
      for try await envelope in stream {
        #expect(envelope.invocationID == invocationID)
        #expect(try await client.shouldApply(envelope))
        received.append(envelope.record)
        try await client.acknowledge(envelope)
      }
      records = received
      #expect(records.last?.event == .runCompleted)
      #expect(records.map(\.sequence) == records.indices.map { UInt64($0 + 1) })
      #expect(records.allSatisfy { $0.runID == runID })
      #expect(try await composition.journal.records(for: runID, after: nil, limit: 256) == records)
      try await client.disconnect()
      try await composition.close()
    } catch {
      try? await client.disconnect()
      try? await composition.close()
      throw error
    }
    let results = records.compactMap { record -> ToolResult? in
      guard case .toolFinished(let result) = record.event else { return nil }
      return result
    }
    #expect(results.map(\.toolCallID.rawValue) == ["produce", "find-marker", "read-marker"])
    #expect(results.allSatisfy { $0.status == .success })
    let original = try #require(results.first)
    let reference = try #require(original.artifacts.first)
    #expect(original.artifacts.count == 1)
    #expect(reference.runID == runID)
    #expect(reference.toolCallID == original.toolCallID)
    #expect(reference.isComplete)
    #expect(await provider.requestCount == 4)
    #expect(await provider.selectedArtifact == reference)
    let final = records.compactMap { record -> Message? in
      guard case .messageAppended(let message) = record.event, message.role == .assistant else {
        return nil
      }
      return message
    }.last
    #expect(final?.content == [.text("done")])

    // New storage owners must reconstruct references from durable manifests and SQLite, not a
    // test double's retained dictionary or the original reader's checksum cache.
    let reopenedStore = try FileArtifactStore(rootURL: artifactURL)
    let reopenedJournal = try await SQLiteAgentEventJournal.open(
      configuration: journalConfiguration)
    let reloaded: [AgentEventRecord]
    do {
      reloaded = try await reopenedJournal.records(for: runID, after: nil, limit: 256)
      try await reopenedJournal.close()
    } catch {
      try? await reopenedJournal.close()
      throw error
    }
    #expect(reloaded == records)
    let reloadedReference = try #require(
      reloaded.compactMap { record -> ArtifactReference? in
        guard case .toolFinished(let result) = record.event,
          result.toolCallID == original.toolCallID
        else { return nil }
        return result.artifacts.first
      }.first)
    #expect(reloadedReference == reference)
    var bytes = Data()
    var offset: Int64 = 0
    repeat {
      let chunk = try await reopenedStore.read(
        reloadedReference, offset: offset, maximumBytes: 65_536)
      #expect(chunk.reference == reference)
      #expect(chunk.offset == offset)
      #expect(!chunk.data.isEmpty)
      bytes.append(chunk.data)
      let next = offset + Int64(chunk.data.count)
      #expect(chunk.nextOffset == (next < reference.byteCount ? next : nil))
      offset = next
    } while offset < reference.byteCount
    #expect(Int64(bytes.count) == reference.byteCount)
    return WorkflowEvidence(originalResult: original, reference: reference, savedBytes: bytes)
  }

  private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private enum Mode: Sendable { case process, structured }
  private enum FixtureError: Error {
    case unexpectedToolResult, missingArtifact, missingMarker, captureTimedOut, streamTimedOut
  }
  private struct WorkflowEvidence: Sendable {
    let originalResult: ToolResult
    let reference: ArtifactReference
    let savedBytes: Data
  }

  /// Only inference is scripted. Its later calls derive the artifact UUID from the real tool
  /// result and the read offset from the real search result, exercising runtime artifact scope.
  private actor WorkflowProvider: InferenceProvider {
    nonisolated let modelID = ModelID(rawValue: "offline-artifact-model")
    nonisolated let descriptor = ProviderDescriptor(
      id: ProviderID(rawValue: "offline-artifact-provider"),
      displayName: "Offline artifact workflow",
      capabilities: [.textInput, .streaming, .toolCalling])
    let mode: Mode
    var requestCount = 0
    var selectedArtifact: ArtifactReference?
    init(mode: Mode) { self.mode = mode }
    func availableModels() async throws -> [ModelDescriptor] {
      [
        ModelDescriptor(
          id: modelID, providerID: descriptor.id, displayName: "Offline workflow",
          capabilities: descriptor.capabilities, maxOutputTokens: 256)
      ]
    }
    func stream(_ request: InferenceRequest) async throws -> InferenceStream {
      try Task.checkCancellation()
      requestCount += 1
      guard requestCount <= 4 else { throw FixtureError.unexpectedToolResult }
      let results = request.messages.flatMap(\.content).compactMap { content -> ToolResult? in
        guard case .toolResult(let result) = content else { return nil }
        return result
      }
      let call: ToolCall?
      if let produced = results.first(where: { $0.toolCallID.rawValue == "produce" }) {
        guard produced.status == .success, let reference = produced.artifacts.first else {
          throw FixtureError.missingArtifact
        }
        selectedArtifact = reference
        let query = mode == .process ? "119999" : "oversized-marker"
        if let search = results.first(where: { $0.toolCallID.rawValue == "find-marker" }) {
          guard search.status == .success, case .object(let output) = search.output,
            case .array(let matches) = output["matches"], case .object(let match) = matches.first,
            case .integer(let offset) = match["offset"]
          else { throw FixtureError.missingMarker }
          if let read = results.first(where: { $0.toolCallID.rawValue == "read-marker" }) {
            guard read.status == .success, case .object(let output) = read.output,
              case .string(let content) = output["content"], content.hasPrefix(query)
            else { throw FixtureError.missingMarker }
            call = nil
          } else {
            call = ToolCall(
              id: ToolCallID(rawValue: "read-marker"), name: "artifact_read",
              arguments: [
                "artifact_id": .string(reference.id.uuidString), "offset": .integer(offset),
                "maximum_bytes": .integer(32),
              ])
          }
        } else {
          call = ToolCall(
            id: ToolCallID(rawValue: "find-marker"), name: "artifact_search",
            arguments: [
              "artifact_id": .string(reference.id.uuidString), "query": .string(query),
              "offset": .integer(max(0, reference.byteCount - 256)),
              "maximum_scan_bytes": .integer(256),
            ])
        }
      } else {
        switch mode {
        case .process:
          call = ToolCall(
            id: ToolCallID(rawValue: "produce"), name: "process_run",
            arguments: [
              "executable": .string("/usr/bin/seq"),
              "arguments": .array([.string("1"), .string("120000")]),
              "timeout_seconds": .integer(10),
            ])
        case .structured:
          call = ToolCall(
            id: ToolCallID(rawValue: "produce"), name: "oversized_fixture", arguments: [:])
        }
      }
      let stream = AsyncThrowingStream<InferenceStreamEvent, any Error> { continuation in
        continuation.yield(.started(providerResponseID: "offline-\(requestCount)"))
        if let call {
          continuation.yield(.toolCall(call))
          continuation.yield(.completed(.toolCalls))
        } else {
          continuation.yield(.textDelta("done"))
          continuation.yield(.completed(.stop))
        }
        continuation.finish()
      }
      return InferenceStream(events: stream, onCancellation: {}, waitForTermination: {})
    }
  }

  private struct OversizedTool: HostTool {
    let definition = ToolDefinition(
      name: "oversized_fixture", description: "Produce one oversized fixture result.",
      inputSchema: [
        "type": .string("object"), "properties": .object([:]),
        "additionalProperties": .boolean(false),
      ])
    func authorizationRequest(for call: ToolCall, in context: ToolExecutionContext) async throws
      -> AuthorizationRequest
    {
      AuthorizationRequest(
        runID: context.runID, toolCallID: call.id,
        capability: CapabilityID(rawValue: "fixture.output"),
        operation: "produce", explanation: "Allow the offline test fixture.")
    }
    func execute(_ call: ToolCall, in context: ToolExecutionContext) async throws -> ToolResult {
      Self.result(callID: call.id)
    }
    static func result(callID: ToolCallID) -> ToolResult {
      ToolResult(
        toolCallID: callID, status: .success,
        output: .object([
          "hex_observation_id": .string("11111111-2222-3333-4444-555555555555"),
          "observation_id": .string("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"),
          "hex_observed_pid": .integer(42), "snapshot": .string("fixture-snapshot"),
          "arbitrary_field": .string("do not promote arbitrary data"),
          "payload": .string(
            String(repeating: "x", count: 2 * 1_024 * 1_024 + 1) + "oversized-marker"),
        ]))
    }
  }
}
