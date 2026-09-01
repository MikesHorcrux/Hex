import Foundation
import HexCore
import Testing

@Suite("Inference stream events")
struct InferenceStreamEventTests {
  @Test
  func roundTripsEveryEventCase() throws {
    let call = ToolCall(
      id: ToolCallID(rawValue: "call-1"),
      name: "terminal",
      arguments: ["command": .string("pwd")]
    )
    let events: [InferenceStreamEvent] = [
      .started(providerResponseID: "response-1"),
      .started(providerResponseID: nil),
      .textDelta("hello"),
      .reasoningSummaryDelta("checking files"),
      .toolCall(call),
      .usage(
        InferenceUsage(
          inputTokens: 10,
          outputTokens: 4,
          cachedInputTokens: 2,
          reasoningTokens: 1
        )
      ),
      .completed(.stop),
    ]

    for event in events {
      #expect(try roundTrip(event) == event)
    }
  }

  @Test
  func roundTripsEveryStopReason() throws {
    let reasons: [InferenceStopReason] = [
      .stop,
      .toolCalls,
      .length,
      .contentFilter,
      .other("provider_specific"),
    ]

    for reason in reasons {
      #expect(try roundTrip(reason) == reason)
      let event = InferenceStreamEvent.completed(reason)
      #expect(try roundTrip(event) == event)
    }
  }

  @Test
  func usageDefaultsOptionalCountersToZero() throws {
    let usage = InferenceUsage(inputTokens: 12, outputTokens: 3)

    #expect(usage.cachedInputTokens == 0)
    #expect(usage.reasoningTokens == 0)
    #expect(try roundTrip(usage) == usage)
  }

  private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(Value.self, from: data)
  }
}
