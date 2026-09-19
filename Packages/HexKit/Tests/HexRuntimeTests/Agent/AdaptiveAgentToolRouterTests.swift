import HexCore
import HexRuntime
import Testing

@Suite("Adaptive agent tool routing")
struct AdaptiveAgentToolRouterTests {
  private let providerID = ProviderID(rawValue: "router-provider")

  private var model: ModelDescriptor {
    ModelDescriptor(
      id: ModelID(rawValue: "router-model"),
      providerID: providerID,
      displayName: "Router model",
      capabilities: [.textInput, .streaming, .toolCalling],
      contextWindow: 32_768,
      maxOutputTokens: 2_048
    )
  }

  private var tools: [ToolDefinition] {
    [
      ToolDefinition(
        name: "workspace_read_text_file", description: "Read a source file.",
        inputSchema: ["type": .string("object")]),
      ToolDefinition(
        name: "workspace_apply_patch", description: "Apply a source patch.",
        inputSchema: ["type": .string("object")]),
      ToolDefinition(
        name: "web_search", description: "Search the web.",
        inputSchema: ["type": .string("object")]),
      ToolDefinition(
        name: "mac_accessibility_snapshot", description: "Inspect the current Mac window.",
        inputSchema: ["type": .string("object")]),
    ]
  }

  private func user(_ text: String) -> [Message] {
    [Message(role: .user, content: [.text(text)])]
  }

  @Test
  func conversationalTurnsDoNotReceiveTools() {
    let router = AdaptiveAgentToolRouter(
      configuration: AgentToolRoutingConfiguration(maximumToolsForCompactContext: 2))
    #expect(!router.shouldDiscoverTools(messages: user("Hey")))
    #expect(
      router.select(definitions: tools, messages: user("Hey"), model: model, toolChoice: .automatic)
        .isEmpty)
  }

  @Test
  func codingTurnsReceiveOnlyTheRelevantDomain() {
    let router = AdaptiveAgentToolRouter(
      configuration: AgentToolRoutingConfiguration(maximumToolsForCompactContext: 2))
    #expect(router.shouldDiscoverTools(messages: user("Fix this code and apply the patch.")))
    let selected = router.select(
      definitions: tools, messages: user("Fix this code and apply the patch."), model: model,
      toolChoice: .automatic)
    #expect(selected.map(\.name) == ["workspace_read_text_file", "workspace_apply_patch"])
  }

  @Test
  func ambiguousActionPreservesTheFullCatalog() {
    let router = AdaptiveAgentToolRouter(
      configuration: AgentToolRoutingConfiguration(maximumToolsForCompactContext: 2))
    let selected = router.select(
      definitions: tools, messages: user("Please execute it."), model: model,
      toolChoice: .automatic)
    #expect(selected == tools)
  }

  @Test
  func explicitToolChoicesPreserveTheAdvertisedSnapshot() {
    let router = AdaptiveAgentToolRouter()
    #expect(
      router.select(definitions: tools, messages: user("Hey"), model: model, toolChoice: .none)
        .isEmpty)
    #expect(
      router.select(definitions: tools, messages: user("Hey"), model: model, toolChoice: .required)
        == tools)
    #expect(
      router.select(
        definitions: tools, messages: user("Hey"), model: model, toolChoice: .named("web_search"))
        == tools)
  }
}
