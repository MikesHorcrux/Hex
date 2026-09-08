import Foundation
import HexCapabilities
import HexCore
import HexGatewayKit
import HexIPC
import HexPersistence
import Testing

@Suite("Gateway shutdown preserves real tool receipts")
struct HexGatewayShutdownWorkflowTests {
  @Test
  func timedOutCloseKeepsJournalOpenUntilStartedToolReturnsItsKnownOutcome() async throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("hex-shutdown-workflow-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)])
    defer { try? FileManager.default.removeItem(at: directory) }
    let call = ToolCall(
      id: ToolCallID(), name: "process_run",
      arguments: [
        "executable": .string("/bin/sh"),
        "arguments": .array([.string("-c"), .string("printf 'ran\\n' >> occurrence-count")]),
        "timeout_seconds": .integer(10),
      ])
    let provider = GatewayTestInferenceProvider(toolCall: call)
    let tool = HeldProcessResult(wrapped: ProcessRunTool(executor: POSIXProcessExecutor()))
    let journalConfiguration = SQLiteAgentEventJournalConfiguration(
      databaseURL: directory.appendingPathComponent("journal.sqlite"))
    let composition = try await HexGatewayComposition.open(
      configuration: HexGatewayCompositionConfiguration(
        journalConfiguration: journalConfiguration, inferenceProvider: provider,
        toolExecutor: try HostToolExecutor(tools: [tool]),
        authorizationProvider: GatewayTestAuthorizationProvider()))
    let client = HexGatewayClient(transport: composition.transport)
    let runID = AgentRunID()
    do {
      _ = try await client.connect()
      _ = try await client.startRun(
        GatewayStartRunRequest(
          runID: runID, modelID: provider.modelID,
          initialMessages: [Message(role: .user, content: [.text("Run once.")])],
          workingDirectory: directory))
      await tool.waitUntilResultHeld()
      // The real process already changed its private workspace, but its result has not returned.
      // A bounded close must not close SQLite or invent a nonexecution/cancellation receipt.
      await #expect(throws: GatewayFailure.self) {
        try await composition.close(timeout: .milliseconds(20))
      }
      let pending = try await composition.journal.records(for: runID, after: nil, limit: 128)
      #expect(pending.contains { $0.event == .toolStarted(call) })
      #expect(!pending.contains { if case .toolFinished = $0.event { true } else { false } })
      #expect(
        try String(
          contentsOf: directory.appendingPathComponent("occurrence-count"), encoding: .utf8)
          == "ran\n")
      // Existing authenticated discovery survives the failed drain; no fresh execution is admitted.
      _ = try await client.recoverRun(GatewayRunRecoveryRequest(runID: runID))
      await #expect(throws: GatewayFailure.self) {
        _ = try await client.startRun(
          GatewayStartRunRequest(
            runID: AgentRunID(), modelID: provider.modelID,
            initialMessages: [Message(role: .user, content: [.text("Must not start.")])]))
      }
      await tool.releaseResult()
      try await composition.close()
      await #expect(throws: SQLiteAgentEventJournalError.self) {
        _ = try await composition.journal.records(for: runID, after: nil, limit: 128)
      }
      let reopened = try await SQLiteAgentEventJournal.open(configuration: journalConfiguration)
      do {
        let records = try await reopened.records(for: runID, after: nil, limit: 128)
        let results = records.compactMap { record -> ToolResult? in
          if case .toolFinished(let result) = record.event { return result }
          return nil
        }
        let result = try #require(results.first)
        #expect(results.count == 1)
        #expect(result.toolCallID == call.id && result.status == .success)
        #expect(result.notExecutedReason == nil)
        #expect(
          records.contains {
            if case .messageAppended(let message) = $0.event {
              return message.role == .tool && message.content == [.toolResult(result)]
            }
            return false
          })
        #expect(records.last?.event == .runCancelled)
        #expect(await tool.executions == 1)
        try await reopened.close()
      } catch {
        try? await reopened.close()
        throw error
      }
    } catch {
      await tool.releaseResult()
      try? await composition.close()
      throw error
    }
  }

  /// The real command completes first; only delivery of its result is held. Ignoring cancellation
  /// at this boundary deliberately represents a worker that has not yet finished its cleanup.
  private actor HeldProcessResult: HostTool {
    nonisolated let definition: ToolDefinition
    private let wrapped: ProcessRunTool
    private var resultHeld = false
    private var release: CheckedContinuation<Void, Never>?
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var executions = 0

    init(wrapped: ProcessRunTool) {
      self.wrapped = wrapped
      definition = wrapped.definition
    }

    func authorizationRequest(for call: ToolCall, in context: ToolExecutionContext) async throws
      -> AuthorizationRequest
    {
      try await wrapped.authorizationRequest(for: call, in: context)
    }

    func execute(_ call: ToolCall, in context: ToolExecutionContext) async throws -> ToolResult {
      executions += 1
      let result = try await wrapped.execute(call, in: context)
      await withCheckedContinuation { continuation in
        release = continuation
        resultHeld = true
        for waiter in entryWaiters { waiter.resume() }
        entryWaiters.removeAll()
      }
      return result
    }

    func waitUntilResultHeld() async {
      if resultHeld { return }
      await withCheckedContinuation { entryWaiters.append($0) }
    }

    func releaseResult() {
      release?.resume()
      release = nil
    }
  }
}
