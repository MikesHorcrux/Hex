import Foundation
import HexCore
import HexIPC
import Testing

@testable import Hex

@Suite("Agent conversation continuity")
struct AgentConversationTests {
  @Test
  func contextUsesRecentUserAndAssistantMessagesWithinBothBounds() {
    let conversation = AgentConversation(
      transcript: [
        ConversationItem(role: .user, text: "Old request"),
        ConversationItem(role: .assistant, text: "Old answer"),
        ConversationItem(role: .event, text: "Tool approval"),
        ConversationItem(role: .user, text: "Recent request"),
        ConversationItem(role: .assistant, text: "Recent answer"),
      ]
    )

    let messages = conversation.boundedContextMessages(
      maximumMessages: 2,
      maximumBytes: 27
    )
    let text = messages.compactMap { message in
      message.content.compactMap { content in
        if case .text(let value) = content {
          return value
        }
        return nil
      }.first
    }

    #expect(text == ["Recent request", "Recent answer"])
    #expect(
      messages.allSatisfy { message in
        message.role == .user || message.role == .assistant
      })
  }

  @Test
  func archiveRoundTripsAndRestoresSelection() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("conversations.json")
    let store = try AgentConversationStore(fileURL: fileURL)
    let conversation = AgentConversation(
      id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE") ?? UUID(),
      title: "Project follow-up",
      transcript: [
        ConversationItem(role: .user, text: "Inspect the project"),
        ConversationItem(role: .assistant, text: "I found the project."),
      ]
    )
    let archive = AgentConversationArchive(
      selectedConversationID: conversation.id,
      conversations: [conversation]
    )

    try await store.save(archive)
    let loaded = try await store.load()

    #expect(loaded == archive)
    let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  }

  @Test
  func corruptAndOversizedArchivesFailClosed() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("conversations.json")
    let store = try AgentConversationStore(fileURL: fileURL, maximumBytes: 256)

    try writePrivateData(Data(#"{\"schemaVersion\":1,"#.utf8), to: fileURL)
    do {
      _ = try await store.load()
      Issue.record("Expected malformed conversation JSON to be rejected.")
    } catch let error as AgentConversationStoreError {
      #expect(error == .malformedArchive)
    }

    try writePrivateData(Data(repeating: 0x20, count: 257), to: fileURL)
    do {
      _ = try await store.load()
      Issue.record("Expected an oversized conversation archive to be rejected.")
    } catch let error as AgentConversationStoreError {
      guard case .archiveTooLarge(_, let maximum) = error else {
        Issue.record("Expected the archive byte limit error, got \(error).")
        return
      }
      #expect(maximum == 256)
    }
  }

  @Test @MainActor
  func nextPromptIncludesPriorConversationContext() async throws {
    let client = RecordingAgentClient()
    let model = AgentWorkspaceModel(
      client: client,
      conversationStore: nil
    )
    await model.connect()

    _ = model.ensureCurrentConversation()
    model.transcript = [
      ConversationItem(role: .user, text: "Earlier request"),
      ConversationItem(role: .assistant, text: "Earlier answer"),
      ConversationItem(role: .tool, text: "A tool result is display-only context."),
    ]
    model.updateCurrentConversation()
    model.draft = "Follow-up request"
    model.send()

    for _ in 0..<100 {
      if await client.requestCount() == 1 {
        break
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }

    let requests = await client.requests()
    let text = try #require(
      requests.first?.initialMessages.compactMap { message in
        message.content.compactMap { content in
          if case .text(let value) = content {
            return value
          }
          return nil
        }.first
      })

    #expect(text == ["Earlier request", "Earlier answer", "Follow-up request"])
  }

  @Test @MainActor
  func restoreSelectsSavedConversationAndClearsStreamingMarker() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("conversations.json")
    let store = try AgentConversationStore(fileURL: fileURL)
    let first = AgentConversation(
      title: "First",
      transcript: [ConversationItem(role: .user, text: "First prompt")]
    )
    let second = AgentConversation(
      title: "Second",
      transcript: [
        ConversationItem(role: .user, text: "Second prompt"),
        ConversationItem(role: .assistant, text: "Second answer", isStreaming: true),
      ]
    )
    try await store.save(
      AgentConversationArchive(
        selectedConversationID: second.id,
        conversations: [first, second]
      )
    )

    let model = AgentWorkspaceModel(
      client: PreviewHexAgentClient(),
      conversationStore: store
    )
    await model.restoreConversationHistory()

    #expect(model.selectedConversationID == second.id)
    #expect(model.transcript.count == 2)
    #expect(model.transcript[1].text == "Second answer")
    #expect(!model.transcript[1].isStreaming)

    model.selectConversation(first.id)
    #expect(model.selectedConversationID == first.id)
    #expect(model.transcript == first.transcript)
  }

  private static func makeTemporaryDirectory() throws -> URL {
    let directory =
      FileManager.default.temporaryDirectory
      .resolvingSymlinksInPath()
      .appendingPathComponent(
        "HexConversationTests-\(UUID().uuidString)",
        isDirectory: true
      )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    return directory
  }

  private func makeTemporaryDirectory() throws -> URL {
    try Self.makeTemporaryDirectory()
  }

  private func writePrivateData(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: [.atomic])
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o600)],
      ofItemAtPath: url.path
    )
  }

  private actor RecordingAgentClient: HexAgentClient {
    private var isConnected = false
    private var recordedRequests: [GatewayStartRunRequest] = []

    func connect() async throws -> GatewayConnectionResult {
      isConnected = true
      let response = GatewayHandshakeResponse(
        sessionID: GatewaySessionID(),
        gatewayInstanceID: GatewayInstanceID(),
        selectedVersion: .current,
        activeRun: nil
      )
      return GatewayConnectionResult(response: response, previousGatewayInstanceID: nil)
    }

    func disconnect() async throws {
      isConnected = false
    }

    func startRun(_ request: GatewayStartRunRequest) async throws -> GatewayStartRunResponse {
      guard isConnected else {
        throw GatewayFailure(code: .notConnected, message: "Not connected.")
      }
      recordedRequests.append(request)
      return GatewayStartRunResponse(
        runID: request.runID,
        disposition: .alreadyTerminal(
          invocationID: GatewayRunInvocationID(rawValue: UUID())
        )
      )
    }

    func eventRecords(
      for runID: AgentRunID,
      invocationID: GatewayRunInvocationID
    ) async throws -> AsyncThrowingStream<GatewayEventEnvelope, any Error> {
      AsyncThrowingStream { continuation in
        continuation.finish()
      }
    }

    func cancelRun(_ request: GatewayCancelRunRequest) async throws -> GatewayCancelRunResponse {
      GatewayCancelRunResponse(
        runID: request.runID,
        invocationID: request.invocationID,
        disposition: .alreadyTerminal
      )
    }

    func shouldApply(_ envelope: GatewayEventEnvelope) async throws -> Bool {
      true
    }

    func acknowledge(_ envelope: GatewayEventEnvelope) async throws {}

    func decideAuthorization(
      _ request: AuthorizationRequest,
      choice: AuthorizationDecisionChoice
    ) async throws {}

    func requests() -> [GatewayStartRunRequest] {
      recordedRequests
    }

    func requestCount() -> Int {
      recordedRequests.count
    }
  }
}
