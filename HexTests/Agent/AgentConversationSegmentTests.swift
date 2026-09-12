import Foundation
import Testing

@testable import Hex

@Suite("Collapsed conversation activity")
struct AgentConversationSegmentTests {
  @Test
  func collapsePreservesOrderAndKeepsMessagesAndEventsVisible() {
    let items: [ConversationItem] = [
      .init(role: .user, text: "Read the project"),
      .init(role: .tool, text: "Started workspace_read_text_file"),
      .init(role: .tool, text: "Full receipt"),
      .init(role: .event, text: "An action needs verification before continuing"),
      .init(role: .tool, text: "Another receipt"),
      .init(role: .assistant, text: "Here is what I found"),
    ]
    let segments = AgentConversationSegment.make(items, collapsesTools: true)
    #expect(segments.flatMap(\.items) == items)
    #expect(segments.map(\.isActivity) == [false, true, false, true, false])
    #expect(segments[2].items.first?.role == .event)
  }

  @Test
  func arrivingReceiptRetainsDisclosureIdentity() {
    let started = ConversationItem(role: .tool, text: "Started process_run")
    let result = ConversationItem(role: .tool, text: "Receipt")
    let before = AgentConversationSegment.make([started], collapsesTools: true)
    let after = AgentConversationSegment.make([started, result], collapsesTools: true)
    #expect(before.first?.id == after.first?.id)
    #expect(after.first?.items == [started, result])
    #expect(AgentConversationSegment.make([started, result], collapsesTools: false).count == 2)
  }
}
