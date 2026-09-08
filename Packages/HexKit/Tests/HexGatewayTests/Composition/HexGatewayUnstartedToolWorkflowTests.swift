import Foundation
import HexCapabilities
import HexCore
import HexGatewayKit
import HexIPC
import HexPersistence
import Testing

@Suite("Gateway never-started tool receipts")
struct HexGatewayUnstartedToolWorkflowTests {
  @Test
  func captureFailurePreservesKnownOutcomeAndClosesOnlyTheUntouchedCall() async throws {
    let evidence = try await runWorkflow(mode: .captureFailure)
    let first = try #require(evidence.results.first { $0.toolCallID == evidence.calls[0].id })
    #expect(first.status == .failure)
    #expect(first.requiresUserAttention)
    #expect(first.notExecutedReason == nil)
    guard case .object(let output) = first.output else { throw FixtureError.invalidResult }
    #expect(output["termination"] == .string("output_capture_failed"))
    #expect(output["output_capture_error"] == .string("quota_exceeded"))
    let artifact = try #require(first.artifacts.first)
    #expect(!artifact.isComplete)
    #expect(evidence.results.map(\.toolCallID) == evidence.calls.map(\.id))
    expectNativeReceipt(first, in: evidence.records)
    try expectUntouchedCallReceipt(in: evidence)
  }

  @Test
  func thrownOutcomeAfterARealSideEffectStaysUnresolvedButUntouchedCallDoesNot() async throws {
    let evidence = try await runWorkflow(mode: .uncertainDispatch)
    #expect(evidence.firstMarkerExists)
    #expect(!evidence.results.contains { $0.toolCallID == evidence.calls[0].id })
    #expect(
      !evidence.records.contains { record in
        guard case .messageAppended(let message) = record.event else { return false }
        return message.content.contains { part in
          guard case .toolResult(let result) = part else { return false }
          return result.toolCallID == evidence.calls[0].id
        }
      })
    #expect(evidence.results.count == 1)
    try expectUntouchedCallReceipt(in: evidence)
  }

  private func expectUntouchedCallReceipt(in evidence: Evidence) throws {
    let second = try #require(evidence.results.first { $0.toolCallID == evidence.calls[1].id })
    #expect(second.status == .failure)
    #expect(second.notExecutedReason == .runStopped)
    #expect(!second.requiresUserAttention)
    #expect(second.artifacts.isEmpty)
    #expect(!evidence.secondMarkerExists)
    #expect(evidence.executedCallIDs == [evidence.calls[0].id])
    let started = evidence.records.compactMap { record -> ToolCallID? in
      guard case .toolStarted(let call) = record.event else { return nil }
      return call.id
    }
    #expect(started == [evidence.calls[0].id])
    expectNativeReceipt(second, in: evidence.records)
    guard case .runFailed(let failure) = evidence.records.last?.event else {
      throw FixtureError.invalidResult
    }
    #expect(!failure.isRetryable)
  }

  private func expectNativeReceipt(_ result: ToolResult, in records: [AgentEventRecord]) {
    let finished = records.filter { $0.event == .toolFinished(result) }
    let native = records.filter { record in
      guard case .messageAppended(let message) = record.event else { return false }
      return message.role == .tool && message.content == [.toolResult(result)]
    }
    #expect(finished.count == 1)
    #expect(native.count == 1)
    if let receipt = finished.first, let message = native.first, let terminal = records.last {
      #expect(receipt.sequence < message.sequence)
      #expect(message.sequence < terminal.sequence)
    }
  }

  private func runWorkflow(mode: Mode) async throws -> Evidence {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("hex-unstarted-workflow-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)])
    defer { try? FileManager.default.removeItem(at: directory) }
    let firstMarker = directory.appendingPathComponent("first-dispatched")
    let secondMarker = directory.appendingPathComponent("second-must-not-run")
    let first = ToolCall(
      id: ToolCallID(rawValue: "first"), name: "process_run",
      arguments: [
        "executable": .string(mode == .captureFailure ? "/usr/bin/seq" : "/usr/bin/touch"),
        "arguments": .array(
          mode == .captureFailure
            ? [.string("1"), .string("120000")] : [.string(firstMarker.path)]),
        "timeout_seconds": .integer(10),
      ])
    let second = ToolCall(
      id: ToolCallID(rawValue: "second"), name: "process_run",
      arguments: [
        "executable": .string("/usr/bin/touch"),
        "arguments": .array([.string(secondMarker.path)]), "timeout_seconds": .integer(10),
      ])
    let calls = [first, second]
    let store = try FileArtifactStore(
      rootURL: directory.appendingPathComponent("artifacts", isDirectory: true),
      maximumArtifactBytes: 16_384, maximumTotalBytes: 32_768)
    let provider = BatchProvider(calls: calls)
    let tool = ObservedProcessTool(
      wrapped: ProcessRunTool(executor: POSIXProcessExecutor(artifactWriter: store)),
      loseOutcomeFor: mode == .uncertainDispatch ? first.id : nil)
    let journalConfiguration = SQLiteAgentEventJournalConfiguration(
      databaseURL: directory.appendingPathComponent("journal.sqlite"))
    let configuration = try #require(
      GatewayConfiguration(
        maximumWireBytes: 262_144, maximumRetainedRecordsPerRun: 64,
        subscriberBufferCapacity: 64))
    let composition = try await HexGatewayComposition.open(
      configuration: HexGatewayCompositionConfiguration(
        journalConfiguration: journalConfiguration, inferenceProvider: provider,
        toolExecutor: try HostToolExecutor(tools: [tool]),
        authorizationProvider: GatewayTestAuthorizationProvider(),
        gatewayConfiguration: configuration, artifactWriter: store, artifactReader: store))
    let client = HexGatewayClient(transport: composition.transport, configuration: configuration)
    let runID = AgentRunID()
    let records: [AgentEventRecord]
    do {
      _ = try await client.connect()
      let admission = try await client.startRun(
        GatewayStartRunRequest(
          runID: runID, modelID: provider.modelID,
          initialMessages: [Message(role: .user, content: [.text("Run this two-call batch.")])],
          workingDirectory: directory))
      let invocation = try #require(admission.invocationID)
      let stream = try await client.eventRecords(for: runID, invocationID: invocation)
      records = try await collect(stream, client: client)
      #expect(try await composition.journal.records(for: runID, after: nil, limit: 128) == records)
      try await client.disconnect()
      try await composition.close()
    } catch {
      try? await client.disconnect()
      try? await composition.close()
      throw error
    }
    #expect(await provider.requestCount == 1)
    #expect(
      records.contains { record in
        guard case .messageAppended(let message) = record.event else { return false }
        return message.role == .assistant && message.content == calls.map(MessageContent.toolCall)
      })
    // Reopen the actual journal so typed receipts must survive SQLite validation and decoding.
    let reopened = try await SQLiteAgentEventJournal.open(configuration: journalConfiguration)
    let restored: [AgentEventRecord]
    do {
      restored = try await reopened.records(for: runID, after: nil, limit: 128)
      try await reopened.close()
    } catch {
      try? await reopened.close()
      throw error
    }
    #expect(restored == records)
    return Evidence(
      calls: calls, records: restored,
      results: restored.compactMap { record in
        guard case .toolFinished(let result) = record.event else { return nil }
        return result
      },
      executedCallIDs: await tool.executedCallIDs,
      firstMarkerExists: FileManager.default.fileExists(atPath: firstMarker.path),
      secondMarkerExists: FileManager.default.fileExists(atPath: secondMarker.path))
  }

  private func collect(
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

  private enum Mode: Sendable { case captureFailure, uncertainDispatch }
  private enum FixtureError: Error { case invalidResult, lostDispatchedOutcome, streamTimedOut }
  private struct Evidence: Sendable {
    let calls: [ToolCall]
    let records: [AgentEventRecord]
    let results: [ToolResult]
    let executedCallIDs: [ToolCallID]
    let firstMarkerExists: Bool
    let secondMarkerExists: Bool
  }

  /// Runs the real process tool. Only the post-dispatch transport loss is injected: the first
  /// command has returned after touching a fixture file before its result is deliberately lost.
  private actor ObservedProcessTool: HostTool {
    nonisolated let definition: ToolDefinition
    private let wrapped: ProcessRunTool
    private let loseOutcomeFor: ToolCallID?
    private(set) var executedCallIDs: [ToolCallID] = []

    init(wrapped: ProcessRunTool, loseOutcomeFor: ToolCallID?) {
      self.wrapped = wrapped
      self.loseOutcomeFor = loseOutcomeFor
      definition = wrapped.definition
    }

    func authorizationRequest(for call: ToolCall, in context: ToolExecutionContext) async throws
      -> AuthorizationRequest
    {
      try await wrapped.authorizationRequest(for: call, in: context)
    }

    func execute(_ call: ToolCall, in context: ToolExecutionContext) async throws -> ToolResult {
      executedCallIDs.append(call.id)
      let result = try await wrapped.execute(call, in: context)
      if call.id == loseOutcomeFor { throw FixtureError.lostDispatchedOutcome }
      return result
    }
  }

  private actor BatchProvider: InferenceProvider {
    nonisolated let modelID = ModelID(rawValue: "offline-unstarted-model")
    nonisolated let descriptor = ProviderDescriptor(
      id: ProviderID(rawValue: "offline-unstarted-provider"), displayName: "Offline batch",
      capabilities: [.textInput, .streaming, .toolCalling, .parallelToolCalling])
    private let calls: [ToolCall]
    private(set) var requestCount = 0

    init(calls: [ToolCall]) { self.calls = calls }

    func availableModels() async throws -> [ModelDescriptor] {
      [
        ModelDescriptor(
          id: modelID, providerID: descriptor.id, displayName: "Offline batch",
          capabilities: descriptor.capabilities, maxOutputTokens: 256)
      ]
    }

    func stream(_ request: InferenceRequest) async throws -> InferenceStream {
      try Task.checkCancellation()
      requestCount += 1
      guard requestCount == 1 else { throw FixtureError.invalidResult }
      let events = AsyncThrowingStream<InferenceStreamEvent, any Error> { continuation in
        continuation.yield(.started(providerResponseID: "offline-batch"))
        for call in calls { continuation.yield(.toolCall(call)) }
        continuation.yield(.completed(.toolCalls))
        continuation.finish()
      }
      return InferenceStream(events: events, onCancellation: {}, waitForTermination: {})
    }
  }
}
