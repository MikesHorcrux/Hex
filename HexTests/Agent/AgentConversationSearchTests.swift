import Foundation
import HexCore
import Testing

@testable import Hex

@Suite("Conversation visible-text search")
struct AgentConversationSearchTests {
  @Test
  func matchesVisibleTitlesAndEveryTranscriptRoleIgnoringCaseAndDiacritics() async throws {
    let titleMatch = AgentConversation(title: "Café planning")
    let rowMatches = [ConversationItemRole.user, .assistant, .tool, .event].map { role in
      AgentConversation(
        title: "Another conversation",
        transcript: [ConversationItem(role: role, text: "Résumé ready")])
    }
    let unrelated = AgentConversation(title: "Unrelated")
    let search = AgentConversationSearch()

    let titleIDs = try await search.matchingConversationIDs(
      in: [titleMatch, unrelated], query: "CAFE")
    #expect(titleIDs == [titleMatch.id])
    let rowIDs = try await search.matchingConversationIDs(
      in: rowMatches + [unrelated], query: "RESUME")
    #expect(rowIDs == Set(rowMatches.map(\.id)))
  }

  @Test
  func normalizesWhitespaceWithoutMatchingAcrossSeparateRows() async throws {
    let matching = AgentConversation(
      transcript: [ConversationItem(role: .assistant, text: "The first\n\t  light is here")])
    let separate = AgentConversation(
      transcript: [
        ConversationItem(role: .user, text: "first"),
        ConversationItem(role: .assistant, text: "light"),
      ])
    let matches = try await AgentConversationSearch().matchingConversationIDs(
      in: [matching, separate], query: " \tfirst\n light  ")
    #expect(matches == [matching.id])
  }

  @Test
  func searchesOnlyCallerSnapshotAndNeverNativeProviderHistory() async throws {
    let hidden = AgentConversation(
      title: "Visible title",
      history: AgentConversationHistory(
        exchanges: [
          AgentConversationExchange(
            runID: AgentRunID(),
            messages: [Message(role: .assistant, content: [.text("private-native-marker")])])
        ]))
    let visible = AgentConversation(title: "private-native-marker")
    let search = AgentConversationSearch()
    #expect(
      try await search.matchingConversationIDs(in: [hidden], query: "private-native-marker").isEmpty
    )
    #expect(
      try await search.matchingConversationIDs(in: [visible], query: "private-native-marker") == [
        visible.id
      ])
    #expect(try await search.matchingConversationIDs(in: [hidden], query: " \n\t") == [hidden.id])
    #expect(try await search.matchingConversationIDs(in: [], query: "anything").isEmpty)
  }

  @Test
  func cancelledSearchThrowsWithoutReturningStaleMatches() async throws {
    let search = AgentConversationSearch()
    let snapshot = [AgentConversation(title: "Matching")]
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await search.matchingConversationIDs(in: snapshot, query: "Matching")
    }
    do {
      _ = try await task.value
      Issue.record("A cancelled search returned matches.")
    } catch is CancellationError {
      // Cancellation reaches the caller so it cannot publish an obsolete result.
    }
  }

  @Test
  func taskIdentityUsesNormalizedQueryAndOrderedConversationRevisionsOnly() {
    let date = Date(timeIntervalSince1970: 1_000)
    let first = AgentConversation(title: "First", createdAt: date)
    let second = AgentConversation(title: "Second", createdAt: date)
    let request = AgentConversationSearchRequest(
      query: " first\n light ", conversations: [first, second])
    #expect(request.query == "first light")
    #expect(request.conversationIDs == [first.id, second.id])
    #expect(request.updatedAt == [date, date])
    #expect(
      request
        == AgentConversationSearchRequest(query: "first light", conversations: [first, second]))
    #expect(
      request != AgentConversationSearchRequest(query: "other", conversations: [first, second]))
    #expect(
      request
        != AgentConversationSearchRequest(query: "first light", conversations: [second, first]))
    #expect(request != AgentConversationSearchRequest(query: "first light", conversations: [first]))

    var changed = first
    changed.title = "Changed title"
    changed.transcript = [ConversationItem(role: .assistant, text: "Different visible content")]
    #expect(
      request
        == AgentConversationSearchRequest(query: "first light", conversations: [changed, second]))
    changed.updatedAt = date.addingTimeInterval(1)
    #expect(
      request
        != AgentConversationSearchRequest(query: "first light", conversations: [changed, second]))
  }
}
