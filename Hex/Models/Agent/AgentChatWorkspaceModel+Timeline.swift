import Foundation
import HexCore
import HexIPC

extension AgentChatWorkspaceModel {
  func loadTimeline(_ id: UUID, before cursor: Int64?, token: UUID) async throws {
    let response = try await taskClient.taskOperation(
      .conversationHistory(id, before: cursor, limit: 40))
    guard token == generation, id == selectedID else { return }
    let displayed = response.timeline.compactMap(Self.display)
    if response.before == nil {
      try await loadLegacy(id, before: nil, token: token, append: true, suffix: displayed)
    } else {
      items = displayed
    }
    guard token == generation, id == selectedID else { return }
    before = response.before
  }

  func loadLegacy(
    _ id: UUID, before cursor: Int64?, token: UUID, append: Bool,
    suffix: [ConversationItem] = []
  ) async throws {
    guard let document = try await storage.conversationStorage(.read(id)).documents.first else {
      if token == generation, id == selectedID { items = append ? suffix : [] }
      return
    }
    let page = try await storage.conversationStorage(
      .entries(
        id, kind: .display, before: cursor,
        limit: 40, revision: document.revision))
    guard token == generation, id == selectedID else { return }
    let old = try page.entries.map {
      try JSONDecoder().decode(ConversationItem.self, from: $0.payload)
    }
    let ids = Set(suffix.map(\.id))
    items = old.filter { !ids.contains($0.id) } + (append ? suffix : [])
    legacyBefore = page.before
    legacyExhausted = page.before == nil
  }

  func earlier() async {
    guard let id = selectedID, !isLoading else { return }
    isLoading = true
    defer { isLoading = false }
    showingEarlier = true
    let token = generation
    do {
      if let before {
        try await loadTimeline(id, before: before, token: token)
      } else if !legacyExhausted {
        try await loadLegacy(id, before: legacyBefore, token: token, append: false)
      }
    } catch { self.error = "Earlier messages could not be loaded. The saved history is unchanged." }
  }

  func latest() {
    showingEarlier = false
    legacyBefore = nil
    legacyExhausted = false
    Task { await refresh() }
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
    case .toolStarted(let name):
      return .init(id: entry.id, role: .tool, text: "Started " + name, timestamp: entry.timestamp)
    case .toolFinished(let result):
      return .init(
        id: entry.id, role: .tool, text: HexJSONValueFormatter.string(from: result.output),
        timestamp: entry.timestamp, artifacts: result.artifacts, toolCallID: result.toolCallID)
    }
  }
}
