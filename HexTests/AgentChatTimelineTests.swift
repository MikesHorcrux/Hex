import Foundation
import HexCore
import HexIPC
import Testing

@testable import Hex

@MainActor
@Suite("Full conversation history")
struct AgentChatTimelineTests {
  @Test
  func openingAndRefreshingKeepsEveryMessageAcrossPageBoundaries() async throws {
    let transport = HistoryClient(count: 93)
    let model = makeModel(transport)
    let id = UUID()
    model.selectedID = id
    try await model.loadTimeline(id, before: nil, token: model.generation)
    #expect(model.items.map(\.text) == (1...93).map { "Message \($0)" })
    await transport.append(105)
    try await model.loadTimeline(id, before: nil, token: model.generation)
    #expect(model.items.map(\.text) == (1...198).map { "Message \($0)" })
    #expect(Set(model.items.map(\.id)).count == 198)
    let calls = await transport.calls
    try await model.loadTimeline(id, before: nil, token: model.generation)
    #expect(await transport.calls == calls + 1)
    #expect(model.items.count == 198)
  }

  @Test
  func failedBackfillKeepsVisibleHistoryAndCanRetryWithoutGaps() async throws {
    let transport = HistoryClient(count: 10)
    let model = makeModel(transport)
    let id = UUID()
    model.selectedID = id
    try await model.loadTimeline(id, before: nil, token: model.generation)
    let before = model.items
    await transport.append(85)
    await transport.failOlderPages(true)
    await #expect(throws: GatewayFailure.self) {
      try await model.loadTimeline(id, before: nil, token: model.generation)
    }
    #expect(model.items == before)
    #expect(model.newestTimelineSequence == 10)
    await transport.failOlderPages(false)
    try await model.loadTimeline(id, before: nil, token: model.generation)
    #expect(model.items.map(\.text) == (1...95).map { "Message \($0)" })
  }

  @Test
  func staleReplyDoesNotReplaceAnotherConversation() async throws {
    let transport = HistoryClient(count: 10)
    let model = makeModel(transport)
    let id = UUID()
    model.selectedID = id
    let oldToken = model.generation
    model.generation = UUID()
    model.items = [.init(role: .user, text: "New conversation")]
    try await model.loadTimeline(id, before: nil, token: oldToken)
    #expect(model.items.map(\.text) == ["New conversation"])
    #expect(!model.didLoadTimeline)
  }

  @Test
  func activitySummaryNamesWorkWithoutHidingAssistantMessages() {
    let items: [ConversationItem] = [
      .init(role: .tool, text: "Started process_run"),
      .init(role: .tool, text: "Process output"),
      .init(role: .tool, text: "Started workspace_read_text_file"),
    ]
    #expect(
      AgentConversationSegment.activitySummary(items)
        == "2 tool calls · process run, workspace read text file")
  }

  private func makeModel(_ transport: HistoryClient) -> AgentChatWorkspaceModel {
    AgentChatWorkspaceModel(
      client: PreviewHexAgentClient(), taskClient: transport, storage: EmptyStorage())
  }

  private actor EmptyStorage: ConversationStorage {
    func conversationStorage(_ request: ConversationStorageRequest)
      -> ConversationStorageResponse
    { .init() }
  }

  private actor HistoryClient: HexGatewayTaskClient {
    var entries: [ConversationTimelineEntry]
    var calls = 0
    var fails = false
    init(count: Int) {
      entries = (1...count).map { Self.entry($0) }
    }
    func append(_ count: Int) {
      let start = entries.count + 1
      entries += (start..<(start + count)).map { Self.entry($0) }
    }
    func failOlderPages(_ value: Bool) { fails = value }
    func taskOperation(_ request: GatewayTaskRequest) throws -> GatewayTaskResponse {
      guard case .conversationHistory(_, let before, let limit) = request else { return .init() }
      calls += 1
      if fails, before != nil {
        throw GatewayFailure(code: .transportUnavailable, message: "Disconnected")
      }
      let older = entries.filter { $0.sequence < (before ?? Int64.max) }
      var response = GatewayTaskResponse()
      response.timeline = Array(older.suffix(limit))
      response.before = older.count > limit ? response.timeline.first?.sequence : nil
      return response
    }
    private static func entry(_ index: Int) -> ConversationTimelineEntry {
      var entry = ConversationTimelineEntry(
        id: UUID(), taskID: UUID(), timestamp: Date(),
        content: .message(
          .init(
            role: index.isMultiple(of: 2) ? .assistant : .user,
            content: [.text("Message \(index)")])))
      entry.sequence = Int64(index)
      return entry
    }
  }
}
