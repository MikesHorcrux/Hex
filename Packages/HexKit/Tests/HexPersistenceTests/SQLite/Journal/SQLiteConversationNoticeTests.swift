import Foundation
import HexCore
import Testing

@testable import HexPersistence

@Suite("Visible conversation progress")
struct SQLiteConversationNoticeTests {
  @Test
  func providerSummaryRemainsVisibleBetweenToolReceipts() {
    let id = UUID()
    let task = UUID()
    let date = Date()
    let entry = SQLiteConversationTimeline.project(
      .inferenceEvent(.reasoningSummaryDelta("Checking the finished page")),
      eventID: id, taskID: task, timestamp: date, includeMessages: true)
    #expect(entry?.id == id)
    #expect(entry?.content == .notice("Checking the finished page"))
    #expect(entry?.timestamp == date)
    #expect(
      SQLiteConversationTimeline.project(
        .inferenceEvent(.reasoningSummaryDelta("  \n")),
        eventID: id, taskID: task, timestamp: date, includeMessages: true) == nil)
  }
}
