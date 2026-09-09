import Foundation
import HexCore
import Testing

@testable import HexIPC

@Suite("Known execution outcomes")
struct GatewayTaskExecutionOutcomeTests {
  @Test func knownNonzeroExitDoesNotBecomeAnUnknownSideEffect() throws {
    let call = ToolCall(name: "process_run", arguments: [:])
    var checkpoint = GatewayTaskCheckpoint()
    checkpoint.started.insert(call.id)
    let result = ToolResult(
      toolCallID: call.id, status: .failure, output: .object(["exit_code": .integer(1)]),
      executionOutcome: .completed)
    checkpoint.results[call.id] = try JSONDecoder().decode(
      ToolResult.self, from: JSONEncoder().encode(result))
    #expect(!checkpoint.hasUncertainEffects)
    checkpoint.results[call.id] = ToolResult(
      toolCallID: call.id, status: .failure, output: .object(["error": .string("lost reply")]))
    #expect(checkpoint.hasUncertainEffects)
  }
}
