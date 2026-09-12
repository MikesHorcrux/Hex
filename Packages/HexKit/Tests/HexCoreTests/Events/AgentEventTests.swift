import Foundation
import HexCore
import Testing

@Suite("Agent events")
struct AgentEventTests {
  @Test
  func roundTripsEveryFailureCode() throws {
    let expectedRawValues = [
      "invalid_request",
      "unsupported_capability",
      "authentication",
      "transport",
      "provider",
      "authorization",
      "tool_execution",
      "journal",
      "invalid_state",
    ]

    #expect(AgentFailureCode.allCases.map(\.rawValue) == expectedRawValues)
    for code in AgentFailureCode.allCases {
      #expect(try roundTrip(code) == code)
    }
  }

  @Test
  func roundTripsEveryEventCase() throws {
    let requestID = AuthorizationRequestID()
    let call = ToolCall(
      id: ToolCallID(rawValue: "call-event"),
      name: "read_file",
      arguments: ["path": .string("/tmp/example")]
    )
    let result = ToolResult(toolCallID: call.id, status: .success, output: .string("value"))
    let inferenceRequest = InferenceRequest(
      providerID: ProviderID(rawValue: "provider"),
      modelID: ModelID(rawValue: "model"),
      messages: []
    )
    let authorizationRequest = AuthorizationRequest(
      id: requestID,
      runID: AgentRunID(),
      toolCallID: call.id,
      capability: CapabilityID(rawValue: "filesystem.read"),
      operation: "read",
      resource: "/tmp/example",
      explanation: "Read the selected file."
    )
    let failure = AgentFailure(
      code: .provider,
      message: "Provider unavailable.",
      isRetryable: true
    )
    let events: [AgentEvent] = [
      .runStarted,
      .messageAppended(Message(role: .user, content: [.text("hello")])),
      .contextCompactionStarted,
      .contextCompacted(
        try AgentContextCompaction(
          ownerRunID: authorizationRequest.runID,
          sourceMessageIDs: [MessageID()], summaryText: "Earlier conversation.",
          providerID: inferenceRequest.providerID, modelID: inferenceRequest.modelID,
          estimatedTokensBefore: 100, estimatedTokensAfter: 20)),
      .inferenceRequested(inferenceRequest),
      .inferenceEvent(.textDelta("hello")),
      .authorizationRequested(authorizationRequest),
      .authorizationDecided(requestID: requestID, decision: .deny(reason: nil)),
      .toolStarted(call),
      .toolFinished(result),
      .runCompleted,
      .runCancelled,
      .runFailed(failure),
    ]

    for event in events {
      #expect(try roundTrip(event) == event)
    }
  }

  @Test
  func recordUsesSchemaVersionOneByDefault() throws {
    let runID = AgentRunID()
    let timestamp = Date(timeIntervalSince1970: 1_725_000_000)
    let record = AgentEventRecord(
      id: AgentEventID(),
      runID: runID,
      sequence: 1,
      timestamp: timestamp,
      event: .runStarted
    )

    #expect(record.schemaVersion == 1)
    #expect(try roundTrip(record) == record)
  }

  @Test
  func failureDefaultsToNonretryableAndProvidesDescription() {
    let failure = AgentFailure(code: .invalidRequest, message: "Invalid request.")

    #expect(failure.isRetryable == false)
    #expect(failure.errorDescription == failure.message)
  }

  private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(Value.self, from: data)
  }
}
