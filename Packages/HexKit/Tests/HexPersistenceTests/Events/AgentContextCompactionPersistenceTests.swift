import Foundation
import HexCore
import Testing

@testable import HexPersistence

@Suite("Context compaction durable journal")
struct AgentContextCompactionPersistenceTests {
  @Test
  func recordsCompactionBeforeItsInferenceWithoutDeletingOriginalMessages() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = JournalTestSupport.configuration(in: directory)
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let runID = AgentRunID()
    let original = Message(role: .user, content: [.text("Original evidence remains intact.")])
    let current = Message(role: .user, content: [.text("Continue the current task.")])
    let compaction = try make(runID: runID, source: original.id)
    let request = InferenceRequest(
      providerID: compaction.providerID, modelID: compaction.modelID,
      messages: [compaction.summaryMessage, current])
    let events: [AgentEvent] = [
      .runStarted, .messageAppended(original), .messageAppended(current),
      .contextCompactionStarted, .contextCompacted(compaction), .inferenceRequested(request),
      .runCompleted,
    ]
    for event in events { _ = try await journal.append(event, to: runID) }
    try await journal.close()
    let reopened = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let records = try await reopened.records(for: runID, after: nil, limit: 20)
    #expect(records.map(\.event) == events)
    #expect(records.allSatisfy { $0.schemaVersion == 1 })
    #expect(AgentEvent.contextCompactionStarted.journalKind == "context_compaction_started")
    #expect(AgentEvent.contextCompacted(compaction).journalKind == "context_compacted")
    try await reopened.close()
  }

  @Test
  func mismatchedOwnerAppendIsAtomicAndCancellationAfterStartedIsValid() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = JournalTestSupport.configuration(in: directory)
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let runID = AgentRunID()
    _ = try await journal.append(.runStarted, to: runID)
    _ = try await journal.append(.contextCompactionStarted, to: runID)
    do {
      _ = try await journal.append(.contextCompacted(try make(runID: AgentRunID())), to: runID)
      Issue.record("Expected a compaction owned by another run to be rejected.")
    } catch let error as SQLiteAgentEventJournalError {
      guard case .corruptRecord = error else {
        Issue.record("Unexpected error: \(error)")
        return
      }
    }
    #expect(try await journal.records(for: runID, after: nil, limit: 20).count == 2)
    _ = try await journal.append(.runCancelled, to: runID)
    try await journal.close()
    let reopened = try await SQLiteAgentEventJournal.open(configuration: configuration)
    #expect(
      try await reopened.records(for: runID, after: nil, limit: 20).map(\.event) == [
        .runStarted, .contextCompactionStarted, .runCancelled,
      ])
    try await reopened.close()
  }

  @Test(arguments: InvalidPhase.allCases)
  func rejectsCompactionOutsideSafeBoundaries(phase: InvalidPhase) throws {
    let runID = AgentRunID()
    let compaction = try make(runID: runID)
    let inference = AgentEvent.inferenceRequested(
      InferenceRequest(
        providerID: compaction.providerID, modelID: compaction.modelID,
        messages: [compaction.summaryMessage]))
    let prior: [AgentEvent]
    let rejected: AgentEvent
    switch phase {
    case .withoutStart:
      prior = []
      rejected = .contextCompacted(compaction)
    case .duplicateStart:
      prior = [.contextCompactionStarted]
      rejected = .contextCompactionStarted
    case .duplicateCompletion:
      prior = [.contextCompactionStarted, .contextCompacted(compaction)]
      rejected = .contextCompacted(compaction)
    case .startAfterInference:
      prior = [inference]
      rejected = .contextCompactionStarted
    case .completionAfterInference:
      prior = [inference]
      rejected = .contextCompacted(compaction)
    case .inferenceWhilePending:
      prior = [.contextCompactionStarted]
      rejected = inference
    }
    var lifecycle = SQLiteRunLifecycleValidator(runID: runID)
    try lifecycle.consume(.runStarted, sequence: 1)
    for (index, event) in prior.enumerated() {
      try lifecycle.consume(event, sequence: UInt64(index + 2))
    }
    #expect(throws: (any Error).self) {
      try lifecycle.consume(rejected, sequence: UInt64(prior.count + 2))
    }
  }

  @Test
  func successfulCompletionCannotHideAnUnfinishedCompaction() throws {
    var lifecycle = SQLiteRunLifecycleValidator(runID: AgentRunID())
    try lifecycle.consume(.runStarted, sequence: 1)
    try lifecycle.consume(.contextCompactionStarted, sequence: 2)
    #expect(throws: (any Error).self) { try lifecycle.validateSuccessfulCompletion() }
  }

  @Test
  func malformedSummaryAndFutureRecordSchemaFailClosed() throws {
    let event = AgentEvent.contextCompacted(try make(runID: AgentRunID()))
    let data = try AgentEventCodec.encode(event: event)
    #expect(try AgentEventCodec.decodeEvent(from: data, schemaVersion: 1) == event)
    #expect(throws: (any Error).self) {
      try AgentEventCodec.decodeEvent(from: data, schemaVersion: 2)
    }
    let malformed = String(decoding: data, as: UTF8.self).replacingOccurrences(
      of: "Safe summary.", with: "")
    #expect(throws: (any Error).self) {
      try AgentEventCodec.decodeEvent(from: Data(malformed.utf8), schemaVersion: 1)
    }
  }

  @Test
  func completedToolBatchesCanCompactRepeatedlyAndReopen() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = JournalTestSupport.configuration(in: directory)
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let runID = AgentRunID()
    let goal = Message(role: .user, content: [.text("Keep the task")])
    var events: [AgentEvent] = [.runStarted, .messageAppended(goal)]
    var priorSummary: Message?
    for _ in 0..<2 {
      let call = ToolCall(name: "echo", arguments: [:])
      let assistant = Message(role: .assistant, content: [.toolCall(call)])
      let result = ToolResult(toolCallID: call.id, status: .success, output: .string("done"))
      let tool = Message(role: .tool, content: [.toolResult(result)])
      let source = (priorSummary.map { [$0] } ?? []) + [assistant, tool]
      let record = try AgentContextCompaction(
        ownerRunID: runID, sourceMessageIDs: source.map(\.id), summaryText: "Verified work",
        providerID: ProviderID(rawValue: "test"), modelID: ModelID(rawValue: "model"),
        estimatedTokensBefore: 1000, estimatedTokensAfter: 100, boundary: .completedToolBatch)
      events += [
        .inferenceRequested(
          InferenceRequest(
            providerID: record.providerID,
            modelID: record.modelID, messages: [goal] + (priorSummary.map { [$0] } ?? []))),
        .messageAppended(assistant), .toolStarted(call), .toolFinished(result),
        .messageAppended(tool), .contextCompactionStarted, .contextCompacted(record),
      ]
      priorSummary = record.summaryMessage
    }
    events.append(.runCompleted)
    for event in events { _ = try await journal.append(event, to: runID) }
    try await journal.close()
    let reopened = try await SQLiteAgentEventJournal.open(configuration: configuration)
    #expect(try await reopened.records(for: runID, after: nil, limit: 100).map(\.event) == events)
    try await reopened.close()
  }

  private func make(runID: AgentRunID, source: MessageID = MessageID()) throws
    -> AgentContextCompaction
  {
    try AgentContextCompaction(
      ownerRunID: runID, sourceMessageIDs: [source], summaryText: "Safe summary.",
      providerID: ProviderID(rawValue: "test"), modelID: ModelID(rawValue: "test-model"),
      estimatedTokensBefore: 1000, estimatedTokensAfter: 100)
  }

  enum InvalidPhase: CaseIterable, Sendable {
    case withoutStart, duplicateStart, duplicateCompletion, startAfterInference,
      completionAfterInference, inferenceWhilePending
  }
}
