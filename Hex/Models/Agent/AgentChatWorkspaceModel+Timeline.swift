import Foundation
import HexCore
import HexIPC

extension AgentChatWorkspaceModel {
  /// Read bounded pages, but retain the complete display transcript. Refresh bridges every page
  /// since the last loaded sequence so a busy run cannot displace the user's earlier messages.
  func loadTimeline(_ id: UUID, before cursor: Int64?, token: UUID) async throws {
    var cursor = cursor
    var pages: [[ConversationTimelineEntry]] = []
    var visited = Set<Int64>()
    repeat {
      try Task.checkCancellation()
      let response = try await taskClient.taskOperation(
        .conversationHistory(id, before: cursor, limit: 40))
      guard token == generation, id == selectedID else { return }
      pages.append(response.timeline.filter { $0.sequence > (newestTimelineSequence ?? 0) })
      let reachedLoaded =
        newestTimelineSequence.map { loaded in
          response.timeline.contains { $0.sequence <= loaded }
        } ?? false
      cursor = reachedLoaded ? nil : response.before
      if let cursor, !visited.insert(cursor).inserted {
        throw GatewayFailure(
          code: .recoveryUnavailable, message: "Conversation history stopped advancing.")
      }
    } while cursor != nil

    let entries = pages.reversed().flatMap { $0 }
    let displayed = entries.compactMap(Self.display)
    let prefix = didLoadTimeline ? items : try await legacyItems(id, token: token)
    guard token == generation, id == selectedID else { return }
    var ids = Set<UUID>()
    items = (prefix + displayed).filter { ids.insert($0.id).inserted }
    newestTimelineSequence = entries.map(\.sequence).max() ?? newestTimelineSequence
    didLoadTimeline = true
  }

  private func legacyItems(_ id: UUID, token: UUID) async throws -> [ConversationItem] {
    guard let document = try await storage.conversationStorage(.read(id)).documents.first else {
      return []
    }
    guard token == generation, id == selectedID else { return [] }
    var cursor: Int64?
    var pages: [[ConversationItem]] = []
    var visited = Set<Int64>()
    repeat {
      try Task.checkCancellation()
      let page = try await storage.conversationStorage(
        .entries(id, kind: .display, before: cursor, limit: 40, revision: document.revision))
      guard token == generation, id == selectedID else { return [] }
      pages.append(
        try page.entries.map {
          try JSONDecoder().decode(ConversationItem.self, from: $0.payload)
        })
      cursor = page.before
      if let cursor, !visited.insert(cursor).inserted {
        throw GatewayFailure(
          code: .recoveryUnavailable, message: "Saved history stopped advancing.")
      }
    } while cursor != nil
    return pages.reversed().flatMap { $0 }
  }

  static func display(_ entry: ConversationTimelineEntry) -> ConversationItem? {
    switch entry.content {
    case .message(let message):
      let text = message.content.compactMap { part -> String? in
        if case .text(let text) = part { return text }
        return nil
      }.joined(separator: "\n")
      guard !text.isEmpty else { return nil }
      return .init(
        id: entry.id, role: message.role == .user ? .user : .assistant,
        text: text, timestamp: entry.timestamp)
    case .notice(let text):
      return .init(id: entry.id, role: .event, text: text, timestamp: entry.timestamp)
    case .toolStarted(let name):
      return .init(id: entry.id, role: .tool, text: "Started " + name, timestamp: entry.timestamp)
    case .toolFinished(let result):
      return .init(
        id: entry.id, role: .tool, text: HexJSONValueFormatter.string(from: result.output),
        timestamp: entry.timestamp, artifacts: result.artifacts, toolCallID: result.toolCallID)
    }
  }
}
