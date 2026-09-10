import Foundation

/// Groups adjacent tool receipts for presentation without changing or dropping the saved timeline.
nonisolated struct AgentConversationSegment: Identifiable, Equatable, Sendable {
  let id: UUID
  var items: [ConversationItem]
  let isActivity: Bool

  static func activitySummary(_ items: [ConversationItem]) -> String {
    let names = items.filter { $0.text.hasPrefix("Started ") }.map {
      String($0.text.dropFirst("Started ".count)).replacingOccurrences(of: "_", with: " ")
    }
    guard !names.isEmpty else { return "\(items.count) tool receipts" }
    var seen = Set<String>()
    let distinct = names.filter { seen.insert($0).inserted }
    let preview = distinct.prefix(2).joined(separator: ", ")
    return "\(names.count) tool \(names.count == 1 ? "call" : "calls") · \(preview)"
      + (distinct.count > 2 ? " and \(distinct.count - 2) more" : "")
  }

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
