import Foundation

nonisolated enum AgentConversationListFilter: String, CaseIterable, Identifiable {
  case conversations
  case archived
  case all

  var id: String { rawValue }

  var title: String {
    switch self {
    case .conversations: "Chats"
    case .archived: "Archived"
    case .all: "All"
    }
  }

  var sectionTitle: String {
    switch self {
    case .conversations: "Conversations"
    case .archived: "Archived conversations"
    case .all: "All conversations"
    }
  }

  func includes(_ conversation: AgentConversation) -> Bool {
    switch self {
    case .conversations: !conversation.isArchived
    case .archived: conversation.isArchived
    case .all: true
    }
  }
}
