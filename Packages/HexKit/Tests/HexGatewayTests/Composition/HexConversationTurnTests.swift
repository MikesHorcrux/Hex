import Foundation
import HexCore
import HexIPC
import HexPersistence
import Testing

@testable import HexGatewayKit

@Suite("Resident conversation continuation")
struct HexConversationTurnTests {
  @Test
  func followUpUsesCompletedAnswerAfterResidentRestartAndKeepsOneConversation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = SQLiteAgentEventJournalConfiguration(
      databaseURL: directory.appendingPathComponent("journal.sqlite"))
    let provider = RecordingProvider()
    var composition = try await open(config, provider)
    var session = try await composition.service.handshake(.init(clientID: GatewayClientID()))
      .sessionID
    let parent = UUID()
    let firstID = UUID()
    let nextID = UUID()
    let first = request("Remember COBALT-42")
    _ = try await composition.service.taskOperation(
      .submitConversation(
        id: firstID, conversationID: parent,
        predecessorID: nil, title: "One conversation", request: first), sessionID: session)
    try await completed(firstID, composition, session)
    try await composition.close()
    composition = try await open(config, provider)
    session = try await composition.service.handshake(.init(clientID: GatewayClientID())).sessionID
    let next = request("What was the marker?")
    _ = try await composition.service.taskOperation(
      .submitConversation(
        id: nextID, conversationID: parent,
        predecessorID: firstID, title: "One conversation", request: next), sessionID: session)
    try await completed(nextID, composition, session)
    let captured = try #require(await provider.requests.last)
    #expect(
      captured.messages.contains { $0.role == .user && $0.content == [.text("Remember COBALT-42")] }
    )
    #expect(captured.messages.contains { $0.role == .assistant })
    #expect(captured.messages.last?.content == [.text("What was the marker?")])
    let replay = try await composition.service.taskOperation(
      .submitConversation(
        id: nextID, conversationID: parent,
        predecessorID: firstID, title: "One conversation", request: next), sessionID: session)
    #expect(replay.tasks.first?.attemptCount == 1)
    let timeline = try await composition.service.taskOperation(
      .conversationHistory(parent, before: nil, limit: 40), sessionID: session
    ).timeline
    #expect(
      timeline.filter {
        if case .message(let m) = $0.content { return m.role == .user }
        return false
      }.count == 2)
    #expect(
      try await composition.service.taskOperation(
        .conversationTasks(parent, before: nil, limit: 20), sessionID: session
      ).tasks.count == 2)
    try await composition.close()
  }

  @Test
  func queuedFollowUpWaitsForPausedParentAndBuildsContextAtDispatch() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = SQLiteAgentEventJournalConfiguration(
      databaseURL: directory.appendingPathComponent("journal.sqlite"))
    let journal = try await SQLiteAgentEventJournal.open(configuration: config)
    let parent = UUID()
    var first = AgentTaskRecord(
      id: UUID(), title: "queued chain", request: try JSONEncoder().encode(request("first")),
      admissionHash: Data([1]))
    first.phase = .paused
    first.conversationID = parent
    first = try await journal.saveTask(first)
    try await journal.close()
    let provider = RecordingProvider()
    let composition = try await open(config, provider)
    let session = try await composition.service.handshake(.init(clientID: GatewayClientID()))
      .sessionID
    let nextID = UUID()
    _ = try await composition.service.taskOperation(
      .submitConversation(
        id: nextID, conversationID: parent,
        predecessorID: first.id, title: "queued chain", request: request("next")),
      sessionID: session)
    let current = try #require(
      try await composition.service.taskOperation(
        .conversationTasks(parent, before: nil, limit: 20), sessionID: session
      ).activeTask)
    #expect(current.id == first.id)
    let steer = try await composition.service.taskOperation(
      .control(
        id: first.id, revision: current.revision,
        operationID: UUID(), action: .steer("Also remember AMBER")), sessionID: session)
    #expect(steer.tasks.first?.phase == .paused)
    #expect(await provider.requests.isEmpty)
    _ = try await composition.service.taskOperation(
      .control(
        id: first.id, revision: try #require(steer.tasks.first?.revision),
        operationID: UUID(), action: .resume), sessionID: session)
    try await completed(nextID, composition, session)
    let last = try #require(await provider.requests.last)
    #expect(last.messages.contains { $0.content == [.text("Also remember AMBER")] })
    #expect(last.messages.contains { $0.role == .assistant })
    try await composition.close()
  }

  @Test
  func legacyCheckpointAdoptsWithoutExecutingAndRetainsOriginalDocument() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = SQLiteAgentEventJournalConfiguration(
      databaseURL: directory.appendingPathComponent("journal.sqlite"))
    let journal = try await SQLiteAgentEventJournal.open(configuration: config)
    let original = request("Old request with known history")
    let start = try await journal.append(.runStarted, to: original.runID)
    _ = try await journal.append(
      .messageAppended(try #require(original.initialMessages.first)), to: original.runID)
    _ = try await journal.append(.runCancelled, to: original.runID)
    let source = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original))
    let first = try JSONSerialization.jsonObject(
      with: JSONEncoder().encode(start.id), options: [.fragmentsAllowed])
    let state = try JSONSerialization.data(withJSONObject: [
      "pendingRun": ["request": source, "firstEventID": first]
    ])
    let id = UUID()
    let document = ConversationStorageDocument(
      id: id, title: "Legacy", createdAt: Date(), updatedAt: Date(), state: state)
    _ = try await journal.conversationStorage(.write(.init(document: document, entries: [])))
    try await journal.close()
    let provider = RecordingProvider()
    let composition = try await open(config, provider)
    let session = try await composition.service.handshake(.init(clientID: GatewayClientID()))
      .sessionID
    _ = try await composition.service.taskOperation(
      .adoptLegacyConversation(id), sessionID: session)
    var recovered: AgentTaskRecord?
    for _ in 0..<200 {
      recovered = try await composition.service.taskOperation(
        .read(original.runID.rawValue), sessionID: session
      ).tasks.first
      if recovered?.phase == .paused { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(recovered?.phase == .paused)
    #expect(recovered?.runID == original.runID)
    #expect(await provider.requests.isEmpty)
    _ = try await composition.service.taskOperation(
      .adoptLegacyConversation(id), sessionID: session)
    #expect(
      try await composition.service.taskOperation(
        .conversationTasks(id, before: nil, limit: 20), sessionID: session
      ).tasks.count == 1)
    try await composition.close()
    let reopened = try await SQLiteAgentEventJournal.open(configuration: config)
    #expect(try await reopened.conversationStorage(.read(id)).documents.first?.state == state)
    try await reopened.close()
  }

  @Test
  func cancelledQueuedMessageKeepsEarlierCompletedContext() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = SQLiteAgentEventJournalConfiguration(
      databaseURL: directory.appendingPathComponent("journal.sqlite"))
    let journal = try await SQLiteAgentEventJournal.open(configuration: config)
    let parent = UUID()
    let seed = GatewayStartRunRequest(
      runID: AgentRunID(), modelID: GatewayTestInferenceProvider().modelID,
      initialMessages: [
        Message(role: .user, content: [.text("Remember EARLIER")]),
        Message(role: .assistant, content: [.text("Saved EARLIER")]),
      ], toolChoice: .none)
    var completed = AgentTaskRecord(
      id: UUID(), title: "Cancellation context", request: try JSONEncoder().encode(seed),
      admissionHash: Data([1]))
    completed.conversationID = parent
    completed.phase = .completed
    _ = try await journal.saveTask(completed)
    var cancelled = AgentTaskRecord(
      id: UUID(), title: "Cancelled message",
      request: try JSONEncoder().encode(request("Never execute this")), admissionHash: Data([2]))
    cancelled.conversationID = parent
    cancelled.predecessorID = completed.id
    cancelled.phase = .cancelled
    _ = try await journal.saveTask(cancelled)
    try await journal.close()
    let provider = RecordingProvider()
    let composition = try await open(config, provider)
    let session = try await composition.service.handshake(.init(clientID: GatewayClientID()))
      .sessionID
    let nextID = UUID()
    _ = try await composition.service.taskOperation(
      .submitConversation(
        id: nextID, conversationID: parent,
        predecessorID: cancelled.id, title: "Cancellation context",
        request: request("What did you save?")), sessionID: session)
    try await self.completed(nextID, composition, session)
    let captured = try #require(await provider.requests.last)
    #expect(captured.messages.contains { $0.content == [.text("Saved EARLIER")] })
    #expect(!captured.messages.contains { $0.content == [.text("Never execute this")] })
    try await composition.close()
  }

  private func request(_ text: String) -> GatewayStartRunRequest {
    .init(
      runID: AgentRunID(), modelID: GatewayTestInferenceProvider().modelID,
      initialMessages: [Message(role: .user, content: [.text(text)])], toolChoice: .none)
  }
  private func open(_ config: SQLiteAgentEventJournalConfiguration, _ provider: RecordingProvider)
    async throws -> HexGatewayComposition
  {
    try await HexGatewayComposition.open(
      configuration: .init(
        journalConfiguration: config,
        inferenceProvider: provider, toolExecutor: GatewayTestToolExecutor(),
        authorizationProvider: GatewayTestAuthorizationProvider()))
  }
  private func completed(
    _ id: UUID, _ composition: HexGatewayComposition, _ session: GatewaySessionID
  ) async throws {
    for _ in 0..<500 {
      let record = try await composition.service.taskOperation(.read(id), sessionID: session).tasks
        .first
      if record?.phase == .completed { return }
      if record?.phase == .blocked {
        Issue.record("Blocked: \(record?.explanation ?? "unknown")")
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Conversation turn did not complete")
  }
  private actor RecordingProvider: InferenceProvider {
    var requests: [InferenceRequest] = []
    nonisolated var descriptor: ProviderDescriptor { GatewayTestInferenceProvider().descriptor }
    func availableModels() async throws -> [ModelDescriptor] {
      try await GatewayTestInferenceProvider().availableModels()
    }
    func stream(_ request: InferenceRequest) async throws -> InferenceStream {
      requests.append(request)
      return try await GatewayTestInferenceProvider().stream(request)
    }
  }
}
