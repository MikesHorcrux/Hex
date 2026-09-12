import Foundation
import HexCore
import HexGatewayKit
import Testing

@Suite("Read-only self inspection")
struct HexSelfInspectionToolExecutorTests {
  @Test
  func returnsOnlyItsOwnRunSnapshotAndManualThroughReadAuthorization() async throws {
    let service = makeService()
    let firstID = AgentRunID()
    let secondID = AgentRunID()
    for (runID, model) in [(firstID, "first-model"), (secondID, "second-model")] {
      _ = try await service.beginRun(
        runID: runID, modelID: ModelID(rawValue: model),
        workingDirectory: nil, options: InferenceOptions()
      )
    }
    let executor = HexSelfInspectionToolExecutor(service: service, base: GatewayTestToolExecutor())
    let tools = try await executor.availableTools()
    #expect(tools.map(\.name) == ["hex_inspect_self"])
    #expect(tools.first?.inputSchema["additionalProperties"] == .boolean(false))
    let call = ToolCall(name: "hex_inspect_self", arguments: [:])
    let context = ToolExecutionContext(runID: firstID)
    let authorization = try await executor.authorizationRequest(for: call, in: context)
    #expect(authorization.capability.rawValue == "hex.self.read")
    #expect(authorization.operation == "inspect")
    #expect(authorization.details.isEmpty)
    #expect(authorization.resource == nil)
    let result = try await executor.execute(call, in: context)
    #expect(result.status == .success)
    #expect(result.toolCallID == call.id)
    guard case .object(let output) = result.output else {
      Issue.record("Expected structured output")
      return
    }
    let expected = try await service.snapshot(for: firstID)
    let other = try await service.snapshot(for: secondID)
    #expect(output["runtime"] == expected)
    #expect(output["runtime"] != other)
    #expect(output["manual"] == .string(HexSelfOperatingManual().text))
    await service.endRun(firstID)
    let ended = try await executor.execute(call, in: context)
    #expect(ended.status == .failure)
    #expect(ended.output == .object(["error": .string("run_unavailable")]))
  }

  @Test
  func rejectsArgumentsAndToolNameCollisionsInsteadOfExposingArbitraryReads() async throws {
    let service = makeService()
    let executor = HexSelfInspectionToolExecutor(service: service, base: GatewayTestToolExecutor())
    let call = ToolCall(name: "hex_inspect_self", arguments: ["path": .string("/private/secret")])
    let context = ToolExecutionContext(runID: AgentRunID())
    await #expect(throws: HexSelfInspectionToolError.invalidArguments) {
      try await executor.authorizationRequest(for: call, in: context)
    }
    let result = try await executor.execute(call, in: context)
    #expect(result.status == .failure)
    #expect(result.output == .object(["error": .string("invalid_arguments")]))
    let collision = HexSelfInspectionToolExecutor(
      service: service,
      base: GatewayTestToolExecutor(
        tool: ToolDefinition(
          name: "hex_inspect_self", description: "External impostor", inputSchema: [:]
        ))
    )
    await #expect(throws: HexSelfInspectionToolError.reservedToolName) {
      try await collision.availableTools()
    }
  }

  @Test
  func delegatesExistingToolsAndPropagatesCancellation() async throws {
    let base = GatewayTestToolExecutor(
      tool: ToolDefinition(
        name: "workspace_probe", description: "Existing host tool", inputSchema: [:]
      ))
    let executor = HexSelfInspectionToolExecutor(service: makeService(), base: base)
    let call = ToolCall(name: "workspace_probe", arguments: [:])
    let context = ToolExecutionContext(runID: AgentRunID())
    #expect(try await executor.availableTools().count == 2)
    let result = try await executor.execute(call, in: context)
    #expect(result.output == .string("recorded"))
    #expect(await base.contexts() == [context])
    let cancelled = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await executor.execute(
        ToolCall(name: "hex_inspect_self", arguments: [:]), in: context)
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
  }

  private func makeService() -> HexSelfKnowledgeService {
    HexSelfKnowledgeService(
      knowledge: HexSelfKnowledge(sourceRootHintURL: nil),
      provider: GatewayTestInferenceProvider().descriptor
    )
  }
}
