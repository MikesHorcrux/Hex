import HexCore
import Testing

@testable import HexRuntime

@Suite("InferenceTurnAccumulator protocol")
struct InferenceTurnAccumulatorTests {
  @Test
  func preservesResponseIDAndContiguousContentOrdering() throws {
    let call = ToolCall(
      id: ToolCallID(rawValue: "call"),
      name: "echo",
      arguments: [:]
    )
    var accumulator = makeAccumulator(toolNames: ["echo"])
    try accept(
      [
        .started(providerResponseID: "provider-response"),
        .textDelta("a"),
        .textDelta("b"),
        .reasoningSummaryDelta("not model content"),
        .toolCall(call),
        .textDelta("c"),
        .completed(.toolCalls),
      ],
      into: &accumulator
    )

    let output = try accumulator.finish()

    #expect(output.providerResponseID == "provider-response")
    #expect(output.assistantMessage.content == [.text("ab"), .toolCall(call), .text("c")])
    #expect(output.toolCalls == [call])
  }

  @Test
  func rejectsEventsBeforeStartedAndDuplicateStarted() throws {
    var beforeStart = makeAccumulator()
    #expect(throws: AgentRuntimeError.self) {
      try beforeStart.accept(.textDelta("invalid"))
    }

    var duplicateStart = makeAccumulator()
    try duplicateStart.accept(.started(providerResponseID: nil))
    #expect(throws: AgentRuntimeError.self) {
      try duplicateStart.accept(.started(providerResponseID: nil))
    }
  }

  @Test
  func rejectsEmptyProviderResponseIDButAllowsNil() throws {
    for responseID in ["", "   \n"] {
      var invalid = makeAccumulator()
      #expect(throws: AgentRuntimeError.self) {
        try invalid.accept(.started(providerResponseID: responseID))
      }
    }

    var absent = makeAccumulator()
    try absent.accept(.started(providerResponseID: nil))
    try absent.accept(.textDelta("valid"))
    try absent.accept(.completed(.stop))
    #expect(try absent.finish().providerResponseID == nil)
  }

  @Test
  func rejectsDuplicateUsageAndAnythingAfterCompleted() throws {
    let usage = InferenceUsage(inputTokens: 1, outputTokens: 1)
    var duplicateUsage = makeAccumulator()
    try duplicateUsage.accept(.started(providerResponseID: nil))
    try duplicateUsage.accept(.usage(usage))
    #expect(throws: AgentRuntimeError.self) {
      try duplicateUsage.accept(.usage(usage))
    }

    var afterCompletion = makeAccumulator()
    try accept(
      [.started(providerResponseID: nil), .textDelta("done"), .completed(.stop)],
      into: &afterCompletion
    )
    #expect(throws: AgentRuntimeError.self) {
      try afterCompletion.accept(.textDelta("late"))
    }
  }

  @Test
  func requiresCompletedAndNonemptyOutput() throws {
    var missingCompletion = makeAccumulator()
    try missingCompletion.accept(.started(providerResponseID: nil))
    try missingCompletion.accept(.textDelta("partial"))
    #expect(throws: AgentRuntimeError.self) {
      try missingCompletion.finish()
    }

    var emptyOutput = makeAccumulator()
    try emptyOutput.accept(.started(providerResponseID: nil))
    try emptyOutput.accept(.completed(.stop))
    #expect(throws: AgentRuntimeError.self) {
      try emptyOutput.finish()
    }
  }

  @Test
  func enforcesToolCallStopReasonPairing() throws {
    var missingCall = makeAccumulator(toolNames: ["echo"])
    try missingCall.accept(.started(providerResponseID: nil))
    #expect(throws: AgentRuntimeError.self) {
      try missingCall.accept(.completed(.toolCalls))
    }

    let call = ToolCall(
      id: ToolCallID(rawValue: "call"),
      name: "echo",
      arguments: [:]
    )
    var wrongReason = makeAccumulator(toolNames: ["echo"])
    try wrongReason.accept(.started(providerResponseID: nil))
    try wrongReason.accept(.toolCall(call))
    #expect(throws: AgentRuntimeError.self) {
      try wrongReason.accept(.completed(.stop))
    }
  }

  @Test
  func rejectsUnknownAndDuplicateToolCalls() throws {
    let call = ToolCall(
      id: ToolCallID(rawValue: "call"),
      name: "echo",
      arguments: [:]
    )
    var unknown = makeAccumulator()
    try unknown.accept(.started(providerResponseID: nil))
    #expect(throws: AgentRuntimeError.self) {
      try unknown.accept(.toolCall(call))
    }

    var duplicate = makeAccumulator(toolNames: ["echo"])
    try duplicate.accept(.started(providerResponseID: nil))
    try duplicate.accept(.toolCall(call))
    #expect(throws: AgentRuntimeError.self) {
      try duplicate.accept(.toolCall(call))
    }

    var prior = makeAccumulator(toolNames: ["echo"], priorIDs: [call.id])
    try prior.accept(.started(providerResponseID: nil))
    #expect(throws: AgentRuntimeError.self) {
      try prior.accept(.toolCall(call))
    }
  }

  @Test
  func rejectsBlankToolCallIdentifiersAndNames() throws {
    let blankIDCall = ToolCall(
      id: ToolCallID(rawValue: " \n "),
      name: "echo",
      arguments: [:]
    )
    var blankID = makeAccumulator(toolNames: ["echo"])
    try blankID.accept(.started(providerResponseID: nil))
    #expect(throws: AgentRuntimeError.self) {
      try blankID.accept(.toolCall(blankIDCall))
    }

    let blankNameCall = ToolCall(
      id: ToolCallID(rawValue: "valid"),
      name: " \n ",
      arguments: [:]
    )
    var blankName = makeAccumulator(toolNames: [" \n "])
    try blankName.accept(.started(providerResponseID: nil))
    #expect(throws: AgentRuntimeError.self) {
      try blankName.accept(.toolCall(blankNameCall))
    }
  }

  @Test
  func rejectsEmptyTextAndReasoningDeltas() throws {
    var text = makeAccumulator()
    try text.accept(.started(providerResponseID: nil))
    #expect(throws: AgentRuntimeError.self) {
      try text.accept(.textDelta(""))
    }

    var reasoning = makeAccumulator()
    try reasoning.accept(.started(providerResponseID: nil))
    #expect(throws: AgentRuntimeError.self) {
      try reasoning.accept(.reasoningSummaryDelta(""))
    }
  }

  private func makeAccumulator(
    toolNames: Set<String> = [],
    priorIDs: Set<ToolCallID> = []
  ) -> InferenceTurnAccumulator {
    InferenceTurnAccumulator(
      budget: .standard,
      allowedToolNames: toolNames,
      priorToolCallIDs: priorIDs,
      remainingToolCalls: AgentRunBudget.standard.maxToolCalls,
      remainingReportedTokens: AgentRunBudget.standard.maxReportedTokens,
      allowsParallelToolCalls: true
    )
  }

  private func accept(
    _ events: [InferenceStreamEvent],
    into accumulator: inout InferenceTurnAccumulator
  ) throws {
    for event in events {
      try accumulator.accept(event)
    }
  }
}
