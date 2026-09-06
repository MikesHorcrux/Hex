import HexCore
import Testing

@testable import HexCapabilities

@Suite("Composite tool executor")
struct CompositeToolExecutorTests {
  @Test("Merges definitions and delegates authorization and execution")
  func mergesAndDelegates() async throws {
    let first = StubExecutor(toolName: "alpha")
    let second = StubExecutor(toolName: "beta")
    let composite = try CompositeToolExecutor(executors: [second, first])

    #expect(try await composite.availableTools().map(\.name) == ["alpha", "beta"])

    let call = ToolCall(name: "beta", arguments: [:])
    let context = ToolExecutionContext(runID: AgentRunID())
    let request = try await composite.authorizationRequest(for: call, in: context)
    let result = try await composite.execute(call, in: context)

    #expect(request.capability.rawValue == "beta")
    #expect(result.toolCallID == call.id)
    #expect(result.content == [.text("beta")])
    #expect(await first.executedNames().isEmpty)
    #expect(await second.executedNames() == ["beta"])
  }

  @Test("Rebuilds routes when a dynamic executor changes")
  func rebuildsDynamicRoutes() async throws {
    let dynamic = StubExecutor(toolName: "before")
    let composite = try CompositeToolExecutor(executors: [dynamic])

    #expect(try await composite.availableTools().map(\.name) == ["before"])
    await dynamic.setToolName("after")
    #expect(try await composite.availableTools().map(\.name) == ["after"])

    await #expect(throws: CompositeToolExecutorError.unknownTool) {
      try await composite.execute(
        ToolCall(name: "before", arguments: [:]),
        in: ToolExecutionContext(runID: AgentRunID())
      )
    }
  }

  @Test("Rejects duplicate names without publishing partial routes")
  func rejectsDuplicateNames() async throws {
    let composite = try CompositeToolExecutor(executors: [
      StubExecutor(toolName: "duplicate"),
      StubExecutor(toolName: "duplicate"),
    ])

    await #expect(throws: CompositeToolExecutorError.duplicateTool("duplicate")) {
      try await composite.availableTools()
    }
    await #expect(throws: CompositeToolExecutorError.unknownTool) {
      try await composite.execute(
        ToolCall(name: "duplicate", arguments: [:]),
        in: ToolExecutionContext(runID: AgentRunID())
      )
    }
  }

  @Test("Discovers independent executors concurrently")
  func discoversConcurrently() async throws {
    let barrier = DiscoveryBarrier(expectedArrivals: 2)
    let composite = try CompositeToolExecutor(executors: [
      BarrierExecutor(toolName: "beta", barrier: barrier),
      BarrierExecutor(toolName: "alpha", barrier: barrier),
    ])

    #expect(try await composite.availableTools().map(\.name) == ["alpha", "beta"])
    #expect(await barrier.arrivalCount() == 2)
  }

  private actor StubExecutor: ToolExecutor {
    private var toolName: String
    private var executed: [String] = []

    init(toolName: String) {
      self.toolName = toolName
    }

    func availableTools() async throws -> [ToolDefinition] {
      [
        ToolDefinition(
          name: toolName,
          description: "Fixture tool.",
          inputSchema: ["type": .string("object")]
        )
      ]
    }

    func authorizationRequest(
      for call: ToolCall,
      in context: ToolExecutionContext
    ) async throws -> AuthorizationRequest {
      AuthorizationRequest(
        runID: context.runID,
        toolCallID: call.id,
        capability: CapabilityID(rawValue: call.name),
        operation: "fixture",
        resource: "fixture://\(call.name)",
        explanation: "Fixture authorization."
      )
    }

    func execute(
      _ call: ToolCall,
      in context: ToolExecutionContext
    ) async throws -> ToolResult {
      _ = context
      executed.append(call.name)
      return ToolResult(
        toolCallID: call.id,
        status: .success,
        output: .object(["tool": .string(call.name)]),
        content: [.text(call.name)]
      )
    }

    func setToolName(_ value: String) {
      toolName = value
    }

    func executedNames() -> [String] {
      executed
    }
  }

  private struct BarrierExecutor: ToolExecutor {
    let toolName: String
    let barrier: DiscoveryBarrier

    func availableTools() async throws -> [ToolDefinition] {
      try await barrier.arrive()
      return [
        ToolDefinition(
          name: toolName,
          description: "Fixture tool.",
          inputSchema: ["type": .string("object")]
        )
      ]
    }

    func authorizationRequest(
      for call: ToolCall,
      in context: ToolExecutionContext
    ) async throws -> AuthorizationRequest {
      _ = call
      _ = context
      throw FixtureError.unexpectedCall
    }

    func execute(
      _ call: ToolCall,
      in context: ToolExecutionContext
    ) async throws -> ToolResult {
      _ = call
      _ = context
      throw FixtureError.unexpectedCall
    }
  }

  private actor DiscoveryBarrier {
    private let expectedArrivals: Int
    private var arrivals = 0

    init(expectedArrivals: Int) {
      self.expectedArrivals = expectedArrivals
    }

    func arrive() async throws {
      arrivals += 1
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: .milliseconds(250))
      while arrivals < expectedArrivals {
        guard clock.now < deadline else {
          throw FixtureError.discoveryWasSerial
        }
        try await Task.sleep(for: .milliseconds(1))
      }
    }

    func arrivalCount() -> Int {
      arrivals
    }
  }

  private enum FixtureError: Error {
    case discoveryWasSerial
    case unexpectedCall
  }
}
