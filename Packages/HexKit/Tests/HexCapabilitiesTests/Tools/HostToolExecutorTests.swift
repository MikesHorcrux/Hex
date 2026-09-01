import HexCapabilities
import HexCore
import Testing

@Suite("Host tool executor")
struct HostToolExecutorTests {
  @Test
  func rejectsInvalidAndDuplicateDefinitions() {
    #expect(throws: HostToolExecutorError.invalidDefinition) {
      _ = try HostToolExecutor(tools: [StubHostTool(name: "bad name")])
    }
    #expect(throws: HostToolExecutorError.duplicateName) {
      _ = try HostToolExecutor(tools: [
        StubHostTool(name: "same"),
        StubHostTool(name: "same"),
      ])
    }
  }

  @Test
  func rejectsUnknownToolsAndMismatchedResults() async throws {
    let executor = try HostToolExecutor(tools: [
      StubHostTool(name: "known", returnsMismatchedID: true)
    ])
    let context = ToolExecutionContext(runID: AgentRunID())

    await #expect(throws: HostToolExecutorError.unknownTool) {
      _ = try await executor.execute(
        ToolCall(name: "unknown", arguments: [:]),
        in: context
      )
    }
    await #expect(throws: HostToolExecutorError.invalidDefinition) {
      _ = try await executor.execute(
        ToolCall(name: "known", arguments: [:]),
        in: context
      )
    }
  }

  private struct StubHostTool: HostTool {
    let definition: ToolDefinition
    let returnsMismatchedID: Bool

    init(name: String, returnsMismatchedID: Bool = false) {
      definition = ToolDefinition(
        name: name,
        description: "A deterministic test tool.",
        inputSchema: [:]
      )
      self.returnsMismatchedID = returnsMismatchedID
    }

    func authorizationRequest(
      for call: ToolCall,
      in context: ToolExecutionContext
    ) async throws -> AuthorizationRequest {
      AuthorizationRequest(
        runID: context.runID,
        toolCallID: call.id,
        capability: CapabilityID(rawValue: "test"),
        operation: "execute",
        explanation: "Test."
      )
    }

    func execute(
      _ call: ToolCall,
      in context: ToolExecutionContext
    ) async throws -> ToolResult {
      ToolResult(
        toolCallID: returnsMismatchedID ? ToolCallID(rawValue: "other") : call.id,
        status: .success,
        output: .object([:])
      )
    }
  }
}
