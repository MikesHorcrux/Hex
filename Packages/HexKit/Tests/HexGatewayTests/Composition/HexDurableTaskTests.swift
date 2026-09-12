import Foundation
import HexCore
import HexIPC
import HexPersistence
import HexRuntime
import Testing

@testable import HexGatewayKit

@Suite("Durable task execution")
struct HexDurableTaskTests {
  @Test
  func nonretryablePreflightFailureIsPreservedWithoutInventingInterruptions() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configuration = HexGatewayCompositionConfiguration(
      journalConfiguration: .init(databaseURL: directory.appendingPathComponent("journal.sqlite")),
      inferenceProvider: GatewayTestInferenceProvider(), toolExecutor: GatewayTestToolExecutor(),
      authorizationProvider: GatewayTestAuthorizationProvider(),
      runtimeConfiguration: .init(budget: try AgentRunBudget(maxInitialInputBytes: 128)))
    let composition = try await HexGatewayComposition.open(configuration: configuration)
    let session = try await composition.service.handshake(.init(clientID: GatewayClientID()))
      .sessionID
    let id = UUID()
    let request = GatewayStartRunRequest(
      runID: AgentRunID(), modelID: GatewayTestInferenceProvider().modelID,
      initialMessages: [
        Message(role: .user, content: [.text(String(repeating: "large", count: 100))])
      ],
      toolChoice: .none)
    _ = try await composition.service.taskOperation(
      .submit(id: id, title: "preflight failure", request: request), sessionID: session)
    let blocked = try await wait(id, phase: .blocked, composition, session)
    #expect(blocked.attemptCount == 1)
    #expect(blocked.retryCount == 0)
    #expect(blocked.explanation.contains("Initial input byte budget exceeded"))
    try await composition.close()
    let reopened = try await HexGatewayComposition.open(
      configuration: .init(
        journalConfiguration: .init(
          databaseURL: directory.appendingPathComponent("journal.sqlite")),
        inferenceProvider: GatewayTestInferenceProvider(), toolExecutor: GatewayTestToolExecutor(),
        authorizationProvider: GatewayTestAuthorizationProvider()))
    let newSession = try await reopened.service.handshake(.init(clientID: GatewayClientID()))
      .sessionID
    let persisted = try await read(id, reopened, newSession)
    #expect(persisted.phase == .blocked)
    #expect(persisted.attemptCount == 1)
    #expect(persisted.explanation == blocked.explanation)
    _ = try await reopened.service.taskOperation(
      .control(
        id: id, revision: persisted.revision, operationID: UUID(),
        action: .reconcile("Continue the original request now.")), sessionID: newSession)
    let done = try await wait(id, phase: .completed, reopened, newSession)
    #expect(done.attemptCount == 2)
    let runID = try #require(done.runID)
    let events = try await reopened.journal.records(for: runID, after: nil, limit: 100).map(\.event)
    #expect(events.contains(.messageAppended(request.initialMessages[0])))
    #expect(
      events.contains { event in
        guard case .messageAppended(let message) = event else { return false }
        return message.role == .user
          && message.content.contains(
            .text(
              "My reconciliation decision for the interrupted attempt: Continue the original request now."
            ))
      })
    try await reopened.close()
  }

  @Test
  func busyWorkQueuesAndPauseDrainsBeforeContinuation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let tool = GatedTool()
    let call = ToolCall(name: "mutate", arguments: ["value": .string("once")])
    let provider = ChoiceProvider(call: call)
    let composition = try await HexGatewayComposition.open(
      configuration: .init(
        journalConfiguration: .init(
          databaseURL: directory.appendingPathComponent("journal.sqlite")),
        inferenceProvider: provider, toolExecutor: tool,
        authorizationProvider: GatewayTestAuthorizationProvider()))
    let session = try await composition.service.handshake(.init(clientID: GatewayClientID()))
      .sessionID
    let id = UUID()
    let request = GatewayStartRunRequest(
      runID: AgentRunID(), modelID: provider.modelID,
      initialMessages: [Message(role: .user, content: [.text("mutate once then finish")])])
    _ = try await composition.service.taskOperation(
      .submit(id: id, title: "first", request: request), sessionID: session)
    for _ in 0..<300 {
      if await tool.started { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await tool.started)
    let secondID = UUID()
    let second = GatewayStartRunRequest(
      runID: AgentRunID(), modelID: provider.modelID,
      initialMessages: [Message(role: .user, content: [.text("second")])], toolChoice: .none)
    _ = try await composition.service.taskOperation(
      .submit(id: secondID, title: "second", request: second), sessionID: session)
    let running = try await read(id, composition, session)
    let pause = try await composition.service.taskOperation(
      .control(
        id: id, revision: running.revision,
        operationID: UUID(), action: .pause), sessionID: session)
    #expect(pause.tasks.first?.phase == .pausing)
    #expect(try await read(secondID, composition, session).phase == .queued)
    await tool.release()
    let paused = try await wait(id, phase: .paused, composition, session)
    #expect(paused.attemptCount == 1)
    _ = try await wait(secondID, phase: .completed, composition, session)
    _ = try await composition.service.taskOperation(
      .control(
        id: id, revision: paused.revision,
        operationID: UUID(), action: .resume), sessionID: session)
    let done = try await wait(id, phase: .completed, composition, session)
    #expect(done.attemptCount == 2)
    #expect(await tool.count == 1)
    let duplicate = try await composition.service.taskOperation(
      .submit(id: id, title: "first", request: request), sessionID: session)
    #expect(duplicate.tasks.first?.id == id)
    #expect(duplicate.tasks.first?.attemptCount == 2)
    try await composition.close()
  }

  @Test
  func queuedAdmissionSurvivesReopeningTheResident() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configuration = SQLiteAgentEventJournalConfiguration(
      databaseURL: directory.appendingPathComponent("journal.sqlite"))
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let request = GatewayStartRunRequest(
      runID: AgentRunID(), modelID: GatewayTestInferenceProvider().modelID,
      initialMessages: [Message(role: .user, content: [.text("survive")])], toolChoice: .none)
    let id = UUID()
    _ = try await journal.saveTask(
      .init(
        id: id, title: "survive", request: JSONEncoder().encode(request), admissionHash: Data([1])))
    try await journal.close()
    let composition = try await HexGatewayComposition.open(
      configuration: .init(
        journalConfiguration: configuration,
        inferenceProvider: GatewayTestInferenceProvider(), toolExecutor: GatewayTestToolExecutor(),
        authorizationProvider: GatewayTestAuthorizationProvider()))
    let session = try await composition.service.handshake(.init(clientID: GatewayClientID()))
      .sessionID
    let done = try await wait(id, phase: .completed, composition, session)
    #expect(done.attemptCount == 1)
    try await composition.close()
  }

  @Test
  func restartContinuesAfterCompletedMutationWithoutRepeatingIt() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configuration = SQLiteAgentEventJournalConfiguration(
      databaseURL: directory.appendingPathComponent("journal.sqlite"))
    let call = ToolCall(name: "mutate", arguments: ["value": .string("once")])
    let provider = CheckpointProvider(call: call)
    let tool = MutationTool(uncertain: false)
    let composition = try await HexGatewayComposition.open(
      configuration: .init(
        journalConfiguration: configuration,
        inferenceProvider: provider, toolExecutor: tool,
        authorizationProvider: GatewayTestAuthorizationProvider()))
    let session = try await composition.service.handshake(.init(clientID: GatewayClientID()))
      .sessionID
    let id = UUID()
    let request = GatewayStartRunRequest(
      runID: AgentRunID(), modelID: GatewayTestInferenceProvider().modelID,
      initialMessages: [Message(role: .user, content: [.text("write once and report")])])
    _ = try await composition.service.taskOperation(
      .submit(id: id, title: "resume", request: request), sessionID: session)
    for _ in 0..<300 {
      if await provider.waitingAfterReceipt { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await provider.waitingAfterReceipt)
    let original = try await read(id, composition, session)
    try await composition.close()
    let reopened = try await HexGatewayComposition.open(
      configuration: .init(
        journalConfiguration: configuration,
        inferenceProvider: ChoiceProvider(call: call), toolExecutor: tool,
        authorizationProvider: GatewayTestAuthorizationProvider()))
    let newSession = try await reopened.service.handshake(.init(clientID: GatewayClientID()))
      .sessionID
    let done = try await wait(id, phase: .completed, reopened, newSession)
    #expect(done.attemptCount == 2)
    #expect(done.runID != original.runID)
    #expect(await tool.count == 1)
    let links = try await reopened.service.taskOperation(
      .attempts(id, before: nil, limit: 20), sessionID: newSession)
    #expect(links.attempts.map(\.number) == [2, 1])
    try await reopened.close()
  }

  @Test
  func unknownMutationBlocksUntilExplicitReconciliation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let tool = MutationTool(uncertain: true)
    let call = ToolCall(name: "mutate", arguments: [:])
    let composition = try await HexGatewayComposition.open(
      configuration: .init(
        journalConfiguration: .init(
          databaseURL: directory.appendingPathComponent("journal.sqlite")),
        inferenceProvider: ChoiceProvider(call: call), toolExecutor: tool,
        authorizationProvider: GatewayTestAuthorizationProvider()))
    let session = try await composition.service.handshake(.init(clientID: GatewayClientID()))
      .sessionID
    let id = UUID()
    let request = GatewayStartRunRequest(
      runID: AgentRunID(), modelID: GatewayTestInferenceProvider().modelID,
      initialMessages: [Message(role: .user, content: [.text("write and report")])])
    _ = try await composition.service.taskOperation(
      .submit(id: id, title: "uncertain", request: request), sessionID: session)
    let blocked = try await wait(id, phase: .blocked, composition, session)
    #expect(blocked.explanation.contains("uncertain"))
    await #expect(throws: GatewayFailure.self) {
      _ = try await composition.service.taskOperation(
        .control(
          id: id, revision: blocked.revision,
          operationID: UUID(), action: .resume), sessionID: session)
    }
    #expect(await tool.count == 1)
    _ = try await composition.service.taskOperation(
      .control(
        id: id, revision: blocked.revision,
        operationID: UUID(),
        action: .reconcile(
          "I verified the write succeeded. Report the result without writing again.")),
      sessionID: session)
    let done = try await wait(id, phase: .completed, composition, session)
    #expect(done.attemptCount == 2)
    #expect(await tool.count == 1)
    try await composition.close()
  }

  private actor CheckpointProvider: InferenceProvider {
    let call: ToolCall
    nonisolated var descriptor: ProviderDescriptor { GatewayTestInferenceProvider().descriptor }
    var waitingAfterReceipt = false
    init(call: ToolCall) { self.call = call }
    func availableModels() async throws -> [ModelDescriptor] {
      try await GatewayTestInferenceProvider().availableModels()
    }
    func stream(_ request: InferenceRequest) async throws -> InferenceStream {
      if request.messages.contains(where: { $0.role == .tool }) {
        waitingAfterReceipt = true
        try await Task.sleep(for: .seconds(30))
      }
      return try await GatewayTestInferenceProvider(toolCall: call).stream(request)
    }
  }

  private actor MutationTool: ToolExecutor {
    let uncertain: Bool
    var count = 0
    init(uncertain: Bool) { self.uncertain = uncertain }
    func availableTools() -> [ToolDefinition] {
      [
        .init(
          name: "mutate", description: "Mutation fixture", inputSchema: ["type": .string("object")])
      ]
    }
    func execute(_ call: ToolCall, in context: ToolExecutionContext) async throws -> ToolResult {
      count += 1
      if uncertain { throw AgentFailure(code: .transport, message: "Lost reply after dispatch") }
      return ToolResult(toolCallID: call.id, status: .success, output: .string("written once"))
    }
  }

  @Test
  func transientFailuresExhaustTheBoundedRetryPolicy() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let provider = FailingProvider()
    let composition = try await HexGatewayComposition.open(
      configuration: .init(
        journalConfiguration: .init(
          databaseURL: directory.appendingPathComponent("journal.sqlite")),
        inferenceProvider: provider, toolExecutor: GatewayTestToolExecutor(),
        authorizationProvider: GatewayTestAuthorizationProvider()))
    let session = try await composition.service.handshake(.init(clientID: GatewayClientID()))
      .sessionID
    let id = UUID()
    let request = GatewayStartRunRequest(
      runID: AgentRunID(), modelID: GatewayTestInferenceProvider().modelID,
      initialMessages: [Message(role: .user, content: [.text("retry boundedly")])],
      toolChoice: .none)
    _ = try await composition.service.taskOperation(
      .submit(id: id, title: "bounded retry", request: request), sessionID: session)
    let blocked = try await wait(id, phase: .blocked, composition, session)
    #expect(blocked.attemptCount == 4)
    #expect(blocked.retryCount == 3)
    #expect(await provider.calls == 4)
    try await composition.close()
  }

  private actor FailingProvider: InferenceProvider {
    var calls = 0
    nonisolated var descriptor: ProviderDescriptor { GatewayTestInferenceProvider().descriptor }
    func availableModels() async throws -> [ModelDescriptor] {
      try await GatewayTestInferenceProvider().availableModels()
    }
    func stream(_ request: InferenceRequest) throws -> InferenceStream {
      calls += 1
      throw AgentFailure(
        code: .transport, message: "Synthetic transient failure", isRetryable: true)
    }
  }

  private func read(_ id: UUID, _ composition: HexGatewayComposition, _ session: GatewaySessionID)
    async throws -> AgentTaskRecord
  {
    try #require(
      try await composition.service.taskOperation(.read(id), sessionID: session).tasks.first)
  }

  private func wait(
    _ id: UUID, phase: AgentTaskPhase, _ composition: HexGatewayComposition,
    _ session: GatewaySessionID
  ) async throws -> AgentTaskRecord {
    for _ in 0..<2000 {
      let record = try await read(id, composition, session)
      if record.phase == phase { return record }
      try await Task.sleep(for: .milliseconds(10))
    }
    let record = try await read(id, composition, session)
    Issue.record("Expected \(phase), got \(record.phase): \(record.explanation)")
    return record
  }

  private struct ChoiceProvider: InferenceProvider {
    let call: ToolCall
    var modelID: ModelID { GatewayTestInferenceProvider().modelID }
    var descriptor: ProviderDescriptor { GatewayTestInferenceProvider().descriptor }
    func availableModels() async throws -> [ModelDescriptor] {
      try await GatewayTestInferenceProvider().availableModels()
    }
    func stream(_ request: InferenceRequest) async throws -> InferenceStream {
      try await GatewayTestInferenceProvider(toolCall: request.toolChoice == .none ? nil : call)
        .stream(request)
    }
  }

  private actor GatedTool: ToolExecutor {
    var started = false
    var count = 0
    var continuation: CheckedContinuation<Void, Never>?
    func availableTools() -> [ToolDefinition] {
      [
        .init(
          name: "mutate", description: "Mutation fixture", inputSchema: ["type": .string("object")])
      ]
    }
    func execute(_ call: ToolCall, in context: ToolExecutionContext) async throws -> ToolResult {
      count += 1
      started = true
      await withCheckedContinuation { continuation = $0 }
      return ToolResult(toolCallID: call.id, status: .success, output: .string("written once"))
    }
    func release() {
      continuation?.resume()
      continuation = nil
    }
  }
}
