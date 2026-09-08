import Foundation
import HexCore
import HexIPC
import Testing

@testable import Hex

@Suite("Workspace compaction capture")
struct AgentWorkspaceCompactionCaptureTests {
  @Test @MainActor
  func matchingOriginalRequestPrefixIsCapturedOnceAndDoesNotMutateTheRequest() throws {
    let fixture = fixture()
    let original = try #require(fixture.model.currentRunRequest)
    let compaction = try compaction(for: original, sources: fixture.earlier.messages)

    try fixture.model.captureHistoryCompaction(compaction)
    try fixture.model.captureHistoryCompaction(compaction)

    let saved = try #require(fixture.model.conversations.first)
    #expect(saved.history?.compactions == [compaction])
    #expect(saved.history?.exchanges.first == fixture.earlier)
    #expect(
      saved.contextMessages() == [compaction.summaryMessage] + original.initialMessages.suffix(1))
    #expect(fixture.model.currentRunRequest == original)
  }

  @Test @MainActor
  func activeSummaryIsCapturedAgainstGeneratedEvidenceAndCanBeReplayed() throws {
    let fixture = fixture()
    let request = try #require(fixture.model.currentRunRequest)
    let call = ToolCall(name: "inspect", arguments: [:])
    let assistant = Message(role: .assistant, content: [.toolCall(call)])
    let tool = Message(
      role: .tool,
      content: [
        .toolResult(
          ToolResult(
            toolCallID: call.id,
            status: .success, output: .string("Observed evidence")))
      ])
    #expect(try fixture.model.captureHistoryMessage(assistant))
    #expect(try fixture.model.captureHistoryMessage(tool))
    let record = try AgentContextCompaction(
      ownerRunID: request.runID,
      sourceMessageIDs: [assistant.id, tool.id], summaryText: "Observed evidence; continue task.",
      providerID: ProviderID(rawValue: "fixture"), modelID: request.modelID,
      estimatedTokensBefore: 1000, estimatedTokensAfter: 100, boundary: .completedToolBatch)
    try fixture.model.captureHistoryCompaction(record)
    try fixture.model.captureHistoryCompaction(record)
    let history = try #require(fixture.model.conversations.first?.history)
    #expect(history.compactions == [record])
    #expect(
      try AgentConversationContextProjection.messages(in: history)
        == request.initialMessages + [record.summaryMessage])
    #expect(history.exchanges.last?.messages.suffix(2) == [assistant, tool])
    #expect(fixture.model.currentRunRequest == request)
  }

  @Test @MainActor
  func alteredReplayMetadataCannotReplaceTheAcceptedSummary() throws {
    let fixture = fixture()
    let request = try #require(fixture.model.currentRunRequest)
    let accepted = try compaction(for: request, sources: fixture.earlier.messages)
    try fixture.model.captureHistoryCompaction(accepted)
    let altered = try compaction(
      for: request, sources: fixture.earlier.messages, id: accepted.id,
      text: "Changed after receipt")

    #expect(throws: GatewayFailure.self) { try fixture.model.captureHistoryCompaction(altered) }

    #expect(fixture.model.conversations.first?.history?.compactions == [accepted])
  }

  @Test @MainActor
  func wrongOwnerModelAndCurrentUserScopeAreRejectedBeforeMutation() throws {
    let fixture = fixture()
    let request = try #require(fixture.model.currentRunRequest)
    let wrongOwner = GatewayStartRunRequest(
      runID: AgentRunID(), modelID: request.modelID, initialMessages: request.initialMessages)
    let wrongModel = GatewayStartRunRequest(
      runID: request.runID, modelID: ModelID(rawValue: "different-model"),
      initialMessages: request.initialMessages)
    let records = [
      try compaction(for: wrongOwner, sources: fixture.earlier.messages),
      try compaction(for: wrongModel, sources: fixture.earlier.messages),
      try compaction(for: request, sources: request.initialMessages),
    ]
    for record in records {
      #expect(throws: GatewayFailure.self) { try fixture.model.captureHistoryCompaction(record) }
    }
    #expect(fixture.model.conversations.first?.history?.compactions.isEmpty == true)
  }

  @Test @MainActor
  func matchingTransportPrefixStillRequiresStoredHistoricalProvenance() throws {
    let fixture = fixture()
    let original = try #require(fixture.model.currentRunRequest)
    let invented = [
      Message(role: .user, content: [.text("Not the preserved request")]),
      Message(role: .assistant, content: [.text("Not the preserved answer")]),
    ]
    let request = GatewayStartRunRequest(
      runID: original.runID, modelID: original.modelID,
      initialMessages: invented + original.initialMessages.suffix(1))
    fixture.model.currentRunRequest = request
    let record = try compaction(for: request, sources: invented)

    #expect(throws: GatewayFailure.self) { try fixture.model.captureHistoryCompaction(record) }

    #expect(fixture.model.conversations.first?.history?.compactions.isEmpty == true)
    #expect(fixture.model.conversations.first?.history?.exchanges.first == fixture.earlier)
  }

  @Test @MainActor
  func strictProjectionAndArchiveValidationCanRunOffMainActor() async throws {
    let fixture = fixture()
    let request = try #require(fixture.model.currentRunRequest)
    let record = try compaction(for: request, sources: fixture.earlier.messages)
    fixture.model.pendingInitialMessageIDs = Set(request.initialMessages.map(\.id))
    let events: [AgentEvent] =
      [.runStarted]
      + request.initialMessages.map(AgentEvent.messageAppended)
      + [.contextCompactionStarted, .contextCompacted(record)]
    for (index, event) in events.enumerated() {
      try fixture.model.reduceRunRecord(
        AgentEventRecord(
          id: AgentEventID(), runID: request.runID, sequence: UInt64(index + 1),
          timestamp: Date(), event: event))
    }
    let conversation = try #require(fixture.model.conversations.first)
    let history = try #require(conversation.history)
    let projected = try await Task.detached {
      try AgentConversationStore.validateForPersistence(
        AgentConversationArchive(
          selectedConversationID: conversation.id, conversations: [conversation]))
      return try AgentConversationContextProjection.messages(in: history)
    }.value

    #expect(projected == [record.summaryMessage] + request.initialMessages.suffix(1))
  }

  @MainActor
  private func fixture(client: any HexAgentClient = PreviewHexAgentClient()) -> (
    model: AgentWorkspaceModel, earlier: AgentConversationExchange
  ) {
    let earlier = AgentConversationExchange(
      runID: AgentRunID(),
      messages: [
        Message(role: .user, content: [.text("Earlier question")]),
        Message(role: .assistant, content: [.text("Earlier answer")]),
      ], outcome: .completed)
    let user = Message(role: .user, content: [.text("Continue")])
    let owner = AgentConversationExchange(runID: AgentRunID(), messages: [user])
    let conversation = AgentConversation(
      title: "Capture fixture", history: AgentConversationHistory(exchanges: [earlier, owner]))
    let model = AgentWorkspaceModel(client: client)
    model.conversations = [conversation]
    model.selectedConversationID = conversation.id
    model.currentRunID = owner.runID
    model.currentRunRequest = GatewayStartRunRequest(
      runID: owner.runID, modelID: ModelID(rawValue: "fixture-model"),
      initialMessages: earlier.messages + [user])
    return (model, earlier)
  }

  @Test(arguments: [true, false]) @MainActor
  func summaryWorkIsStoredAndShownWithoutCallingMissingUsageFree(known: Bool) async throws {
    let fixture = fixture(client: SummaryClient(knownUsage: known))
    let request = try #require(fixture.model.currentRunRequest)
    await fixture.model.startRun(request)
    #expect(fixture.model.runState == .completed)
    let history = try #require(fixture.model.conversations.first?.history)
    let record = try #require(history.compactions.first)
    #expect(record.reportedTokens == (known ? 321 : nil))
    #expect(record.inferenceCalls == (known ? 2 : nil))
    let restored = try JSONDecoder().decode(
      AgentConversationHistory.self,
      from: JSONEncoder().encode(history))
    #expect(restored == history)
    let text = fixture.model.transcript.map(\.text).joined(separator: "\n")
    #expect(text.contains(known ? "321 reported tokens" : "Summary usage unavailable"))
    if known { #expect(text.contains("2 inference calls")) }
  }

  private actor SummaryClient: HexAgentClient {
    let knownUsage: Bool
    var request: GatewayStartRunRequest?
    init(knownUsage: Bool) { self.knownUsage = knownUsage }
    func connect() async throws -> GatewayConnectionResult {
      GatewayConnectionResult(
        response: GatewayHandshakeResponse(
          sessionID: GatewaySessionID(),
          gatewayInstanceID: GatewayInstanceID(), selectedVersion: .current, activeRun: nil),
        previousGatewayInstanceID: nil)
    }
    func disconnect() async throws {}
    func startRun(_ request: GatewayStartRunRequest) async throws -> GatewayStartRunResponse {
      self.request = request
      return GatewayStartRunResponse(
        runID: request.runID,
        disposition: .started(invocationID: GatewayRunInvocationID(rawValue: UUID())))
    }
    func eventRecords(for runID: AgentRunID, invocationID: GatewayRunInvocationID) async throws
      -> AsyncThrowingStream<GatewayEventEnvelope, any Error>
    {
      let request = try #require(request)
      let compaction = try AgentContextCompaction(
        ownerRunID: runID,
        sourceMessageIDs: request.initialMessages.dropLast().map(\.id), summaryText: "Prior work.",
        providerID: ProviderID(rawValue: "fixture"), modelID: request.modelID,
        estimatedTokensBefore: 2_000, estimatedTokensAfter: 100,
        reportedTokens: knownUsage ? 321 : nil, inferenceCalls: knownUsage ? 2 : nil)
      let events: [AgentEvent] = [
        .runStarted, .contextCompactionStarted, .contextCompacted(compaction),
        .messageAppended(Message(role: .assistant, content: [.text("Done.")])), .runCompleted,
      ]
      return AsyncThrowingStream { continuation in
        for (index, event) in events.enumerated() {
          continuation.yield(
            GatewayEventEnvelope(
              invocationID: invocationID,
              record: AgentEventRecord(
                id: AgentEventID(), runID: runID, sequence: UInt64(index + 1),
                timestamp: Date(), event: event)))
        }
        continuation.finish()
      }
    }
    func cancelRun(_ request: GatewayCancelRunRequest) async throws -> GatewayCancelRunResponse {
      GatewayCancelRunResponse(
        runID: request.runID, invocationID: request.invocationID,
        disposition: .alreadyTerminal)
    }
    func shouldApply(_ envelope: GatewayEventEnvelope) async throws -> Bool { true }
    func acknowledge(_ envelope: GatewayEventEnvelope) async throws {}
    func decideAuthorization(_ request: AuthorizationRequest, choice: AuthorizationDecisionChoice)
      async throws
    {}
  }

  private func compaction(
    for request: GatewayStartRunRequest, sources: [Message], id: UUID = UUID(),
    text: String = "The earlier question was answered."
  ) throws -> AgentContextCompaction {
    try AgentContextCompaction(
      id: id, ownerRunID: request.runID, sourceMessageIDs: sources.map(\.id), summaryText: text,
      providerID: ProviderID(rawValue: "fixture"), modelID: request.modelID,
      estimatedTokensBefore: 2_000, estimatedTokensAfter: 100)
  }
}
