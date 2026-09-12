import Foundation
import HexCore
import HexRuntime
import Testing

@Suite("Conservative context token estimation")
struct ConservativeAgentContextTokenEstimatorTests {
  @Test
  func usesSerializedUTF8AndFramingRatherThanCharacterCount() throws {
    let message = Message(role: .user, content: [.text("Hello 🐑 漢字")])
    let tool = ToolDefinition(
      name: "inspect", description: "Tool",
      inputSchema: [
        "type": .string("object"),
        "properties": .object(["path": .object(["type": .string("string")])]),
      ])
    let estimator = ConservativeAgentContextTokenEstimator()
    #expect(try estimator.estimateTokens(in: message) == JSONEncoder().encode(message).count + 16)
    #expect(try estimator.estimateTokens(in: tool) == JSONEncoder().encode(tool).count + 8)
  }

  @Test
  func toolResultImagesAreUnestimatedEvenWhenTheURLIsShort() throws {
    let image = ImageContent(
      sourceURL: URL(fileURLWithPath: "/not-read.png"), mediaType: "image/png")
    let result = ToolResult(
      toolCallID: ToolCallID(rawValue: "call"), status: .success, output: .null,
      content: [.image(image)]
    )
    #expect(throws: AgentContextPlanningError.imageCostUnavailable) {
      try ConservativeAgentContextTokenEstimator().estimateTokens(
        in: Message(role: .tool, content: [.toolResult(result)])
      )
    }
  }

  @Test
  func mediaAllowanceIsScopedToExactProviderAndModelAndIncludesEachImage() throws {
    let model = RuntimeTestFixture.model()
    let estimator = ConservativeAgentContextTokenEstimator(
      imageTokenUpperBounds: [model.providerID: [model.id: 2_000]])
    let image = ImageContent(
      sourceURL: URL(fileURLWithPath: "/never-opened.png"), mediaType: "image/png")
    let message = Message(role: .user, content: [.image(image), .image(image)])
    #expect(
      try estimator.estimateTokens(in: message, model: model)
        == JSONEncoder().encode(message).count + 16 + 4_000)
    let other = RuntimeTestFixture.model(providerID: ProviderID(rawValue: "other"))
    #expect(throws: AgentContextPlanningError.imageCostUnavailable) {
      try estimator.estimateTokens(in: message, model: other)
    }
    let planner = try AgentContextPlanner(estimator: estimator)
    guard
      case .fits(let budget) = try planner.plan(
        pinnedMessages: [], messages: [message],
        tools: [RuntimeTestFixture.tool()], model: model, outputReserveTokens: 256)
    else {
      Issue.record("Expected model-aware image admission")
      return
    }
    #expect(budget.historyTokens > 4_000)
    #expect(budget.toolSchemaTokens > 0)
    #expect(budget.outputReserveTokens == 256)
  }

  @Test(arguments: [0, -1, Int.max])
  func invalidOrOverflowingMediaAllowanceFailsClosed(allowance: Int) throws {
    let model = RuntimeTestFixture.model()
    let estimator = ConservativeAgentContextTokenEstimator(
      imageTokenUpperBounds: [model.providerID: [model.id: allowance]])
    let image = ImageContent(
      sourceURL: URL(fileURLWithPath: "/never-opened.png"), mediaType: "image/png")
    #expect(throws: (any Error).self) {
      try estimator.estimateTokens(
        in: Message(role: .user, content: [.image(image), .image(image)]), model: model)
    }
  }

  @Test
  func invalidJSONSchemaReturnsATypedErrorWithoutItsContents() {
    let tool = ToolDefinition(
      name: "invalid", description: "Sensitive description",
      inputSchema: [
        "private": .number(.infinity)
      ])
    #expect(throws: AgentContextPlanningError.unserializableContent) {
      try ConservativeAgentContextTokenEstimator().estimateTokens(in: tool)
    }
  }
}
