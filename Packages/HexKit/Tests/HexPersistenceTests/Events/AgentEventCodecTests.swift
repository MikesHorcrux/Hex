import Foundation
import HexCore
import Testing

@testable import HexPersistence

@Suite("Agent event persistence codec")
struct AgentEventCodecTests {
  @Test
  func roundTripsEveryAgentEventCase() throws {
    let requestID = AuthorizationRequestID()
    let runID = AgentRunID()
    let call = ToolCall(
      id: ToolCallID(rawValue: "codec-call"),
      name: "read_file",
      arguments: ["path": .string("/tmp/example")]
    )
    let result = ToolResult(
      toolCallID: call.id,
      status: .success,
      output: .string("contents")
    )
    let inferenceRequest = InferenceRequest(
      providerID: ProviderID(rawValue: "provider"),
      modelID: ModelID(rawValue: "model"),
      messages: [Message(role: .user, content: [.text("hello")])]
    )
    let authorizationRequest = AuthorizationRequest(
      id: requestID,
      runID: runID,
      toolCallID: call.id,
      capability: CapabilityID(rawValue: "filesystem.read"),
      operation: "read",
      explanation: "Read the selected file."
    )
    let events: [AgentEvent] = [
      .runStarted,
      .messageAppended(Message(role: .assistant, content: [.text("hello")])),
      .inferenceRequested(inferenceRequest),
      .inferenceEvent(.started(providerResponseID: "response")),
      .authorizationRequested(authorizationRequest),
      .authorizationDecided(requestID: requestID, decision: .deny(reason: "No grant")),
      .toolStarted(call),
      .toolFinished(result),
      .runCompleted,
      .runCancelled,
      .runFailed(AgentFailure(code: .provider, message: "Unavailable")),
    ]

    for event in events {
      let payload = try AgentEventCodec.encode(event: event)
      let decoded = try AgentEventCodec.decodeEvent(
        from: payload,
        schemaVersion: Int64(AgentEventCodec.recordSchemaVersion)
      )
      #expect(decoded == event)
    }
  }
}
