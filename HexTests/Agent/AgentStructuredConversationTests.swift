import Foundation
import HexCore
import HexIPC
import Testing

@testable import Hex

@Suite("Structured conversation behavior")
struct AgentStructuredConversationTests {
  @Test @MainActor
  func nativeToolHistorySurvivesSaveReloadAndFollowUp() async throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("hex-native-history-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AgentConversationStore(
      fileURL: directory.appendingPathComponent("history.json"))
    let client = RecordingClient(mode: .tools)
    let model = AgentWorkspaceModel(client: client, conversationStore: store)
    await model.restoreConversationHistory()
    await model.connect()
    model.draft = "Inspect this image"
    model.send()
    await model.runTask?.value
    await model.conversationPersistenceTask?.value
    #expect(model.runState == .completed)
    let first = try #require(await client.requests.first)
    let committed = await client.nativeMessages

    let restored = AgentWorkspaceModel(client: client, conversationStore: store)
    await restored.restoreConversationHistory()
    await restored.connect()
    restored.draft = "What did you find?"
    restored.send()
    await restored.runTask?.value
    await restored.conversationPersistenceTask?.value
    let followUp = try #require(await client.requests.last)
    #expect(Array(followUp.initialMessages.dropLast()) == first.initialMessages + committed)
    #expect(restored.errorMessage == nil)
  }

  @Test @MainActor
  func replayedSuffixFinishesOnePartialAssistantRow() async throws {
    let client = RecordingClient(mode: .interrupted)
    let model = AgentWorkspaceModel(client: client)
    await model.connect()
    model.draft = "Say hello"
    model.send()
    // Delivery recovery transfers ownership to a new task. Await the final owner, not just the
    // original stream task, and prove that automatic recovery never readmits the user's request.
    for _ in 0..<200 where model.runTask != nil {
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(model.runTask == nil)
    #expect(model.connectionState == .connected)
    let requests = await client.requests
    #expect(requests.count == 1)
    #expect(await client.recoveryRequests.map(\.runID) == requests.map(\.runID))
    #expect(model.runState == .completed)
    #expect(model.transcript.filter { $0.role == .assistant }.map(\.text) == ["Hello"])
  }

  @Test @MainActor
  func terminalRetryDoesNotRepeatACommittedToolAction() async throws {
    let client = RecordingClient(mode: .failedAfterTool)
    let model = AgentWorkspaceModel(client: client)
    await model.connect()
    model.draft = "Perform an action"
    model.send()
    await model.runTask?.value
    #expect(model.runState == .failed)
    #expect(!model.canRetryLastFailure)
    model.retryLastFailure()
    await model.runTask?.value
    #expect(await client.requests.count == 1)
    #expect(model.errorMessage?.contains("already") == true)
  }

  @Test @MainActor
  func interruptedRunCannotBeSilentlyReplacedByANewPrompt() async throws {
    let client = RecordingClient(mode: .interruptedUnknown)
    let model = AgentWorkspaceModel(client: client)
    await model.connect()
    model.draft = "First request"
    model.send()
    await model.runTask?.value
    let interruptedID = model.currentRunID
    await model.connect()
    await model.runTask?.value
    model.draft = "Do it again"
    model.send()
    #expect(model.currentRunID == interruptedID)
    #expect(model.draft == "Do it again")
    #expect(await client.requests.count == 1)
    #expect(model.errorMessage != nil)
  }

  @Test
  func contextKeepsWholeNativeExchangesBeyondTheOldDisplaySlice() {
    let exchanges = (0..<20).map { index in
      AgentConversationExchange(
        runID: AgentRunID(),
        messages: [
          Message(role: .user, content: [.text("Question \(index)")]),
          Message(role: .assistant, content: [.text(String(repeating: "answer", count: 300))]),
        ], outcome: .completed)
    }
    let conversation = AgentConversation(history: AgentConversationHistory(exchanges: exchanges))
    #expect(conversation.contextMessages() == exchanges.flatMap(\.messages))
    #expect(conversation.contextMessages().count == 40)
  }

  @Test @MainActor
  func legacyPartialDraftStaysOutOfContextAfterRestoreSwitchAndSave() async throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("hex-legacy-partial-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AgentConversationStore(
      fileURL: directory.appendingPathComponent("history.json"))
    let conversation = AgentConversation(transcript: [
      ConversationItem(role: .user, text: "Earlier question"),
      ConversationItem(role: .assistant, text: "Half an answer", isStreaming: true),
    ])
    let other = AgentConversation()
    try await store.save(
      AgentConversationArchive(
        selectedConversationID: conversation.id,
        conversations: [conversation, other]))
    let client = RecordingClient(mode: .tools)
    let model = AgentWorkspaceModel(client: client, conversationStore: store)
    await model.restoreConversationHistory()
    model.selectConversation(other.id)
    model.selectConversation(conversation.id)
    await model.conversationPersistenceTask?.value
    await model.connect()
    model.draft = "Continue"
    model.send()
    await model.runTask?.value
    await model.conversationPersistenceTask?.value
    let request = try #require(await client.requests.first)
    #expect(request.initialMessages.map(\.role) == [.user, .user])
    #expect(model.transcript.contains { $0.text == "Half an answer" })
  }

  @Test @MainActor
  func collidingToolIdentitiesRemainStoredButCannotBeSentAsAmbiguousContext() async throws {
    let call = ToolCall(name: "inspect", arguments: [:])
    let exchanges = (0..<2).map { _ in
      AgentConversationExchange(
        runID: AgentRunID(),
        messages: [
          Message(role: .user, content: [.text("Inspect")]),
          Message(role: .assistant, content: [.toolCall(call)]),
          Message(
            role: .tool,
            content: [
              .toolResult(
                ToolResult(
                  toolCallID: call.id, status: .success, output: .null))
            ]),
        ], outcome: .completed)
    }
    let conversation = AgentConversation(history: AgentConversationHistory(exchanges: exchanges))
    let client = RecordingClient(mode: .tools)
    let model = AgentWorkspaceModel(client: client)
    model.conversations = [conversation]
    model.selectedConversationID = conversation.id
    await model.connect()
    model.draft = "Follow up"
    model.send()
    #expect(await client.requests.isEmpty)
    #expect(model.draft == "Follow up")
    #expect(model.conversations.first?.history?.exchanges == exchanges)
    #expect(model.errorMessage?.contains("original history is preserved") == true)
  }

  private actor RecordingClient: HexAgentClient {
    enum Mode { case tools, interrupted, interruptedUnknown, failedAfterTool }
    let mode: Mode
    private(set) var requests: [GatewayStartRunRequest] = []
    private(set) var recoveryRequests: [GatewayRunRecoveryRequest] = []
    private let gatewayInstanceID = GatewayInstanceID()
    private var invocationIDs: [AgentRunID: GatewayRunInvocationID] = [:]
    private var streamCount = 0
    let call = ToolCall(name: "inspect", arguments: ["path": .string("/sample/image.png")])
    let nativeMessages: [Message]

    init(mode: Mode) {
      self.mode = mode
      let result = ToolResult(
        toolCallID: call.id, status: .success,
        output: .object([
          "found": .boolean(true), "nested": .array([.integer(7)]),
        ]),
        content: [
          .image(
            ImageContent(
              sourceURL: URL(fileURLWithPath: "/sample/image.png"), mediaType: "image/png"))
        ])
      nativeMessages = [
        Message(role: .assistant, content: [.toolCall(call)]),
        Message(role: .tool, content: [.toolResult(result)]),
        Message(role: .assistant, content: [.text("Found it.")]),
      ]
    }

    func connect() async throws -> GatewayConnectionResult {
      GatewayConnectionResult(
        response: GatewayHandshakeResponse(
          sessionID: GatewaySessionID(), gatewayInstanceID: gatewayInstanceID,
          selectedVersion: .current, activeRun: nil), previousGatewayInstanceID: nil)
    }
    func disconnect() async throws {}
    func startRun(_ request: GatewayStartRunRequest) async throws -> GatewayStartRunResponse {
      requests.append(request)
      let invocationID = GatewayRunInvocationID(rawValue: UUID())
      invocationIDs[request.runID] = invocationID
      return GatewayStartRunResponse(
        runID: request.runID,
        disposition: .started(invocationID: invocationID))
    }
    func eventRecords(for runID: AgentRunID, invocationID: GatewayRunInvocationID) async throws
      -> AsyncThrowingStream<GatewayEventEnvelope, any Error>
    {
      try await eventRecords(for: runID, invocationID: invocationID, afterSequence: 0)
    }

    func eventRecords(
      for runID: AgentRunID, invocationID: GatewayRunInvocationID, afterSequence: UInt64
    ) async throws -> AsyncThrowingStream<GatewayEventEnvelope, any Error> {
      streamCount += 1
      let request = try #require(requests.last)
      let events: [AgentEvent]
      var interruption: GatewayFailure?
      var sequenceOffset: UInt64 = 0
      if mode == .interrupted || mode == .interruptedUnknown {
        if streamCount == 1 {
          events =
            [.runStarted] + request.initialMessages.map(AgentEvent.messageAppended)
            + [.inferenceEvent(.textDelta("Hel"))]
          interruption = GatewayFailure(
            code: .disconnected, message: "Lost stream", isRetryable: true)
        } else {
          sequenceOffset = UInt64(request.initialMessages.count + 2)
          #expect(afterSequence == sequenceOffset)
          events = [
            .inferenceEvent(.textDelta("lo")),
            .messageAppended(Message(role: .assistant, content: [.text("Hello")])), .runCompleted,
          ]
        }
      } else if requests.count == 1 {
        events =
          request.initialMessages.map(AgentEvent.messageAppended)
          + [.messageAppended(nativeMessages[0]), .toolStarted(call)]
          + nativeMessages.dropFirst().map(AgentEvent.messageAppended)
          + [
            mode == .failedAfterTool
              ? .runFailed(
                AgentFailure(code: .provider, message: "Provider failed", isRetryable: true))
              : .runCompleted
          ]
      } else {
        events = [.runCompleted]
      }
      return AsyncThrowingStream { continuation in
        for (index, event) in events.enumerated() {
          continuation.yield(
            GatewayEventEnvelope(
              invocationID: invocationID,
              record: AgentEventRecord(
                id: AgentEventID(), runID: runID, sequence: sequenceOffset + UInt64(index + 1),
                timestamp: Date(), event: event)))
        }
        continuation.finish(throwing: interruption)
      }
    }

    func recoverRun(_ request: GatewayRunRecoveryRequest) async throws -> GatewayRunRecoveryResponse
    {
      recoveryRequests.append(request)
      if mode == .interruptedUnknown {
        return GatewayRunRecoveryResponse(
          gatewayInstanceID: gatewayInstanceID, runID: request.runID, disposition: .unknown)
      }
      let original = try #require(requests.first(where: { $0.runID == request.runID }))
      let invocationID = try #require(invocationIDs[request.runID])
      return GatewayRunRecoveryResponse(
        gatewayInstanceID: gatewayInstanceID, runID: request.runID,
        disposition: .resident(
          snapshot: GatewayRunSnapshot(
            runID: request.runID, invocationID: invocationID, phase: .running,
            latestSequence: UInt64(original.initialMessages.count + 5)),
          minimumReplaySequence: 0, journal: nil))
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
}
