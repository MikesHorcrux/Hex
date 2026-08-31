import Foundation
import HexCore
import Testing

@Suite("ToolExecutor contract")
struct ToolExecutorContractTests {
  @Test
  func discoveryIsDynamic() async throws {
    let first = ToolDefinition(name: "first", description: "First", inputSchema: [:])
    let second = ToolDefinition(name: "second", description: "Second", inputSchema: [:])
    let executor = ToolExecutorStub(tools: [first])

    #expect(try await executor.availableTools() == [first])
    await executor.replaceTools(with: [second])
    #expect(try await executor.availableTools() == [second])
  }

  @Test
  func discoveryMayThrowInfrastructureFailure() async {
    let executor = ToolExecutorStub(tools: [], discoveryShouldThrow: true)

    do {
      _ = try await executor.availableTools()
      Issue.record("Expected discovery to throw.")
    } catch let error as ToolExecutorStub.StubError {
      #expect(error == .discovery)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func executionPreservesCallIDAndContext() async throws {
    let executor = ToolExecutorStub(tools: [])
    let call = ToolCall(
      id: ToolCallID(rawValue: "call-preserved"),
      name: "terminal",
      arguments: ["command": .string("pwd")]
    )
    let context = ToolExecutionContext(
      runID: AgentRunID(),
      workingDirectory: URL(fileURLWithPath: "/tmp/hex", isDirectory: true)
    )

    let result = try await executor.execute(call, in: context)
    let execution = await executor.lastExecution()

    #expect(result.toolCallID == call.id)
    #expect(execution?.call == call)
    #expect(execution?.context == context)
  }

  @Test
  func executionPropagatesCancellation() async {
    let executor = ToolExecutorStub(tools: [], executionDelay: .seconds(30))
    let call = ToolCall(name: "wait", arguments: [:])
    let context = ToolExecutionContext(runID: AgentRunID())
    let task = Task {
      try await executor.execute(call, in: context)
    }

    while await executor.executionCount() == 0 {
      await Task.yield()
    }
    task.cancel()

    do {
      _ = try await task.value
      Issue.record("Expected execution cancellation.")
    } catch is CancellationError {
      // CancellationError is the required contract boundary.
    } catch {
      Issue.record("Expected CancellationError, received: \(error)")
    }
  }

  actor ToolExecutorStub: ToolExecutor {
    enum StubError: Error, Equatable {
      case discovery
    }

    struct Execution: Sendable {
      let call: ToolCall
      let context: ToolExecutionContext
    }

    private var tools: [ToolDefinition]
    private let discoveryShouldThrow: Bool
    private let executionDelay: Duration?
    private var executions: [Execution] = []

    init(
      tools: [ToolDefinition],
      discoveryShouldThrow: Bool = false,
      executionDelay: Duration? = nil
    ) {
      self.tools = tools
      self.discoveryShouldThrow = discoveryShouldThrow
      self.executionDelay = executionDelay
    }

    func availableTools() async throws -> [ToolDefinition] {
      if discoveryShouldThrow {
        throw StubError.discovery
      }
      return tools
    }

    func execute(
      _ call: ToolCall,
      in context: ToolExecutionContext
    ) async throws -> ToolResult {
      executions.append(Execution(call: call, context: context))
      if let executionDelay {
        try await Task.sleep(for: executionDelay)
      }
      return ToolResult(toolCallID: call.id, status: .success, output: .null)
    }

    func replaceTools(with tools: [ToolDefinition]) {
      self.tools = tools
    }

    func lastExecution() -> Execution? {
      executions.last
    }

    func executionCount() -> Int {
      executions.count
    }
  }
}
