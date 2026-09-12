import Foundation
import HexCore
import Testing

@testable import Hex

@Suite("Active compaction history projection")
struct AgentConversationActiveCompactionTests {
  @Test
  func multipleActiveSummariesPreserveOriginalsAndProjectAcrossLaterTurns() throws {
    let runID = AgentRunID()
    let goal = Message(role: .user, content: [.text("Original goal")])
    let first = batch()
    let second = batch()
    let one = try record(runID, sources: first)
    let two = try record(runID, sources: [one.summaryMessage] + second)
    let final = Message(role: .assistant, content: [.text("Finished")])
    let exchange = AgentConversationExchange(
      runID: runID,
      messages: [goal] + first + second + [final], outcome: .completed)
    let history = AgentConversationHistory(exchanges: [exchange], compactions: [one, two])
    #expect(
      try AgentConversationContextProjection.messages(in: history)
        == [goal, two.summaryMessage, final])
    #expect(history.exchanges[0] == exchange)
    let retry = AgentConversationExchange(
      runID: AgentRunID(), messages: [goal, final],
      outcome: .completed, retryOfRunID: runID)
    let retried = AgentConversationHistory(exchanges: [exchange, retry], compactions: [one, two])
    #expect(try AgentConversationContextProjection.messages(in: retried) == [goal, final])
    let decoded = try JSONDecoder().decode(
      AgentConversationHistory.self,
      from: JSONEncoder().encode(history))
    #expect(
      try AgentConversationContextProjection.messages(in: decoded)
        == [goal, two.summaryMessage, final])
  }

  @Test
  func unfinishedBatchAndOriginalGoalCannotBeReplaced() throws {
    let runID = AgentRunID()
    let goal = Message(role: .user, content: [.text("Original goal")])
    let messages = batch()
    let exchange = AgentConversationExchange(runID: runID, messages: [goal] + messages)
    for sources in [[goal] + messages, [messages[0]]] {
      let history = AgentConversationHistory(
        exchanges: [exchange],
        compactions: [try record(runID, sources: sources)])
      #expect(throws: (any Error).self) {
        try AgentConversationContextProjection.messages(in: history)
      }
    }
  }

  private func batch() -> [Message] {
    let call = ToolCall(name: "echo", arguments: [:])
    return [
      Message(role: .assistant, content: [.toolCall(call)]),
      Message(
        role: .tool,
        content: [
          .toolResult(
            ToolResult(
              toolCallID: call.id,
              status: .success, output: .string("Observed evidence")))
        ]),
    ]
  }

  private func record(_ run: AgentRunID, sources: [Message]) throws -> AgentContextCompaction {
    try AgentContextCompaction(
      ownerRunID: run, sourceMessageIDs: sources.map(\.id),
      summaryText: "Completed evidence; outstanding work remains.",
      providerID: ProviderID(rawValue: "test"), modelID: ModelID(rawValue: "model"),
      estimatedTokensBefore: 1000, estimatedTokensAfter: 100, boundary: .completedToolBatch)
  }
}
