import Foundation

/// Groups adjacent tool receipts for presentation without changing or dropping the saved timeline.
nonisolated struct AgentConversationSegment: Identifiable, Equatable, Sendable {
  let id: UUID
  var items: [ConversationItem]
  let isActivity: Bool

  static func make(_ items: [ConversationItem], collapsesTools: Bool) -> [Self] {
    var result: [Self] = []
    for item in items {
      let isActivity = collapsesTools && item.role == .tool
      if isActivity, let last = result.indices.last, result[last].isActivity {
        result[last].items.append(item)
      } else {
        result.append(Self(id: item.id, items: [item], isActivity: isActivity))
      }
    }
    return result
  }
}
