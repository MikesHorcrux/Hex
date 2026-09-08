import Foundation
import HexCore
import Testing

@testable import HexRuntime

@Suite("Preserved artifact inventory in runtime context")
struct AgentRuntimeArtifactInventoryTests {
  @Test
  func compactionRetainsExplicitAndInlineReferencesWithoutInventingToolHistory() async throws {
    let inline = reference()
    let explicit = reference()
    let original = history(reference: inline)
    let call = ToolCall(name: "artifact_list", arguments: [:])
    let provider = provider(scripts: [
      .events(RuntimeTestFixture.toolEvents([call])),
      .events(RuntimeTestFixture.textEvents()),
    ])
    let executor = ScriptedToolExecutor(tools: [RuntimeTestFixture.tool("artifact_list")])
    let journal = RecordingEventJournal()
    let runtime = AgentRuntime(
      inferenceProvider: provider, toolExecutor: executor,
      authorizationProvider: ScriptedAuthorizationProvider(), journal: journal,
      contextSummarizer: SummaryWithoutArtifactIDs())
    let request = AgentRunRequest(
      runID: AgentRunID(), modelID: RuntimeTestFixture.modelID,
      initialMessages: original, availableArtifacts: [explicit, inline, explicit])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let encodedRequest = try encoder.encode(request)
    _ = try await runtime.run(request)
    #expect(try encoder.encode(request) == encodedRequest)

    let requests = await provider.requests()
    #expect(requests.count == 2)
    let first = try #require(requests.first)
    let second = try #require(requests.last)
    let host = try #require(first.messages.first)
    #expect(host.role == .developer)
    #expect(text(host).contains("2 artifact references"))
    #expect(text(host).contains("artifact_list"))
    #expect(!text(host).contains(inline.id.uuidString))
    #expect(!text(host).contains(explicit.id.uuidString))
    #expect(first.messages.count < original.count)
    #expect(
      !first.messages.contains { message in
        message.content.contains {
          if case .toolResult = $0 { return true }
          return false
        }
      })
    #expect(Array(second.messages.prefix(first.messages.count)) == first.messages)
    #expect(await executor.contexts().first?.artifacts == [explicit, inline])

    let events = await journal.events()
    let originals = events.compactMap { event -> Message? in
      if case .messageAppended(let message) = event { return message }
      return nil
    }
    #expect(Array(originals.prefix(original.count)) == original)
    #expect(!originals.contains(host))
    let compaction = try #require(
      events.compactMap { event -> AgentContextCompaction? in
        if case .contextCompacted(let record) = event { return record }
        return nil
      }.first)
    #expect(!compaction.sourceMessageIDs.contains(host.id))
    #expect(!compaction.summaryText.contains(inline.id.uuidString))
    #expect(await runtime.runArtifacts.isEmpty)
    #expect(await runtime.runArtifactContextMessages.isEmpty)
  }

  @Test
  func fullInventoryUsesConstantSizedDiscoveryContextWithoutClippingReferences() async throws {
    let references = (0..<256).map { _ in reference() }
    let call = ToolCall(name: "artifact_list", arguments: [:])
    let provider = provider(scripts: [
      .events(RuntimeTestFixture.toolEvents([call])),
      .events(RuntimeTestFixture.textEvents()),
    ])
    let executor = ScriptedToolExecutor(tools: [RuntimeTestFixture.tool("artifact_list")])
    let runtime = RuntimeTestFixture.runtime(provider: provider, executor: executor)
    _ = try await runtime.run(
      AgentRunRequest(
        runID: AgentRunID(), modelID: RuntimeTestFixture.modelID,
        initialMessages: [Message(role: .user, content: [.text("List prior output")])],
        availableArtifacts: references))
    let host = try #require(await provider.requests().first?.messages.first)
    #expect(text(host).contains("256 artifact references"))
    #expect(text(host).utf8.count < 1_024)
    #expect(await executor.contexts().first?.artifacts == references)
  }

  @Test(arguments: [true, false])
  func malformedOrConflictingInventoryIsRejectedBeforeAdmission(conflicting: Bool) async throws {
    let original = reference()
    let invalid = ArtifactReference(
      id: original.id, runID: original.runID, mediaType: original.mediaType,
      byteCount: conflicting ? original.byteCount + 1 : -1,
      sha256: original.sha256, isComplete: true)
    let provider = provider(scripts: [])
    let journal = RecordingEventJournal()
    let runtime = RuntimeTestFixture.runtime(
      provider: provider, executor: ScriptedToolExecutor(tools: []), journal: journal)
    await #expect(throws: AgentRuntimeError.self) {
      try await runtime.run(
        AgentRunRequest(
          runID: AgentRunID(), modelID: RuntimeTestFixture.modelID,
          initialMessages: history(reference: original), availableArtifacts: [invalid]))
    }
    #expect(await provider.requests().isEmpty)
    #expect(await journal.events().isEmpty)
    #expect(await runtime.runArtifacts.isEmpty)
  }

  @Test
  func combinedInventoryOverflowIsRejectedInsteadOfSilentlyDroppingOldOutput() async throws {
    let provider = provider(scripts: [])
    let journal = RecordingEventJournal()
    let runtime = RuntimeTestFixture.runtime(
      provider: provider, executor: ScriptedToolExecutor(tools: []), journal: journal)
    await #expect(throws: AgentRuntimeError.self) {
      try await runtime.run(
        AgentRunRequest(
          runID: AgentRunID(), modelID: RuntimeTestFixture.modelID,
          initialMessages: history(reference: reference()),
          availableArtifacts: (0..<256).map { _ in reference() }))
    }
    #expect(await provider.requests().isEmpty)
    #expect(await journal.events().isEmpty)
  }

  @Test
  func hostProjectionAndOutOfBandInventoryAreChargedToInitialByteBudget() async throws {
    let original = [Message(role: .user, content: [.text("hello")])]
    let initialBytes = try JSONEncoder().encode(original).count
    let provider = provider(scripts: [])
    let journal = RecordingEventJournal()
    // Initial input cannot exceed the conversation bound in a valid configuration, so there is
    // no separate smaller-conversation-budget admission case to manufacture here.
    let budget = try AgentRunBudget(maxInitialInputBytes: initialBytes)
    let runtime = RuntimeTestFixture.runtime(
      provider: provider, executor: ScriptedToolExecutor(tools: []), journal: journal,
      configuration: AgentRuntimeConfiguration(budget: budget))
    do {
      _ = try await runtime.run(
        AgentRunRequest(
          runID: AgentRunID(), modelID: RuntimeTestFixture.modelID,
          initialMessages: original, availableArtifacts: [reference()]))
      Issue.record("Expected inventory admission byte budget rejection.")
    } catch let error as AgentRuntimeError {
      guard case .budgetExceeded = error else {
        Issue.record("Wrong error: \(error)")
        return
      }
    }
    #expect(await journal.events().isEmpty)
    #expect(await provider.requests().isEmpty)
  }

  @Test
  func explicitInventoryBytesAreChargedEvenWhenTheHostMessageItselfFits() async throws {
    let original = [Message(role: .user, content: [.text("hello")])]
    let host = try #require(AgentArtifactContext.message(preservedCount: 1))
    let projectionBytes = try JSONEncoder().encode([host] + original).count
    let provider = provider(scripts: [])
    let journal = RecordingEventJournal()
    let budget = try AgentRunBudget(maxInitialInputBytes: projectionBytes)
    let runtime = RuntimeTestFixture.runtime(
      provider: provider, executor: ScriptedToolExecutor(tools: []), journal: journal,
      configuration: AgentRuntimeConfiguration(budget: budget))
    await #expect(throws: AgentRuntimeError.self) {
      try await runtime.run(
        AgentRunRequest(
          runID: AgentRunID(), modelID: RuntimeTestFixture.modelID,
          initialMessages: original, availableArtifacts: [reference()]))
    }
    #expect(await journal.events().isEmpty)
  }

  @Test
  func discoveryBlockParticipatesInInitialAndContinuingTokenBudgets() async throws {
    let provider = provider(scripts: [], contextWindow: 2_000)
    let journal = RecordingEventJournal()
    let runtime = AgentRuntime(
      inferenceProvider: provider, toolExecutor: ScriptedToolExecutor(tools: []),
      authorizationProvider: ScriptedAuthorizationProvider(), journal: journal,
      contextEstimator: InventoryCostEstimator())
    let request = AgentRunRequest(
      runID: AgentRunID(), modelID: RuntimeTestFixture.modelID,
      initialMessages: [Message(role: .user, content: [.text("hello")])],
      availableArtifacts: [reference()])
    do {
      _ = try await runtime.run(request)
      Issue.record("Expected pinned discovery context to exceed the small model's budget.")
    } catch let error as AgentRuntimeError {
      guard case .budgetExceeded = error else {
        Issue.record("Wrong error: \(error)")
        return
      }
    }
    #expect(await provider.requests().isEmpty)
    let model = try #require(await provider.availableModels().first)
    let host = try #require(AgentArtifactContext.message(preservedCount: 1))
    await #expect(throws: AgentRuntimeError.self) {
      try await runtime.validateContinuingContext(
        [host] + request.initialMessages, request: request, model: model, tools: [])
    }
    try await runtime.validateContinuingContext(
      request.initialMessages, request: request, model: model, tools: [])
  }

  private struct SummaryWithoutArtifactIDs: AgentContextSummarizing {
    func summarize(_ request: AgentContextSummaryRequest) async throws -> AgentContextSummaryResult
    {
      AgentContextSummaryResult(
        text: "Earlier task completed; inspect prior output next.", reportedTokens: 0,
        inferenceCalls: 1)
    }
  }

  private struct InventoryCostEstimator: AgentContextTokenEstimating {
    func estimateTokens(in message: Message) throws -> Int {
      message.role == .developer ? 2_000 : 1
    }
    func estimateTokens(in tool: ToolDefinition) throws -> Int { 1 }
  }

  private func reference() -> ArtifactReference {
    ArtifactReference(
      id: UUID(), runID: AgentRunID(), mediaType: "text/plain", byteCount: 10,
      sha256: String(repeating: "a", count: 64), isComplete: true)
  }

  private func text(_ message: Message) -> String {
    message.content.compactMap {
      if case .text(let value) = $0 { return value }
      return nil
    }.joined()
  }

  private func history(reference: ArtifactReference) -> [Message] {
    let call = ToolCall(name: "historical_output", arguments: [:])
    let old = [
      Message(role: .user, content: [.text("Save the initial output")]),
      Message(role: .assistant, content: [.toolCall(call)]),
      Message(
        role: .tool,
        content: [
          .toolResult(
            ToolResult(
              toolCallID: call.id, status: .success, output: .string("Saved"),
              artifacts: [reference]))
        ]),
      Message(role: .assistant, content: [.text("Saved the result")]),
    ]
    return old
      + (0..<10).flatMap { index in
        [
          Message(
            role: .user,
            content: [.text("Question \(index) " + String(repeating: "x", count: 1_000))]),
          Message(
            role: .assistant,
            content: [.text("Answer \(index) " + String(repeating: "y", count: 1_000))]),
        ]
      } + [Message(role: .user, content: [.text("Inspect prior output")])]
  }

  private func provider(scripts: [InferenceScript], contextWindow: Int = 8_192)
    -> ScriptedInferenceProvider
  {
    ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(),
      models: [
        ModelDescriptor(
          id: RuntimeTestFixture.modelID, providerID: RuntimeTestFixture.providerID,
          displayName: "Inventory test", capabilities: RuntimeTestFixture.standardCapabilities,
          contextWindow: contextWindow, maxOutputTokens: 256)
      ], scripts: scripts)
  }
}
