import Foundation
import HexCore
import HexRuntime

enum RuntimeTestFixture {
  static let providerID = ProviderID(rawValue: "test-provider")
  static let modelID = ModelID(rawValue: "test-model")

  static let standardCapabilities: Set<InferenceCapability> = [
    .textInput,
    .streaming,
    .toolCalling,
    .parallelToolCalling,
  ]

  static func descriptor(
    capabilities: Set<InferenceCapability> = standardCapabilities
  ) -> ProviderDescriptor {
    ProviderDescriptor(
      id: providerID,
      displayName: "Test Provider",
      capabilities: capabilities
    )
  }

  static func model(
    capabilities: Set<InferenceCapability> = standardCapabilities,
    providerID: ProviderID = providerID,
    maxOutputTokens: Int? = 4_096
  ) -> ModelDescriptor {
    ModelDescriptor(
      id: modelID,
      providerID: providerID,
      displayName: "Test Model",
      capabilities: capabilities,
      contextWindow: 32_768,
      maxOutputTokens: maxOutputTokens
    )
  }

  static func tool(_ name: String = "echo") -> ToolDefinition {
    ToolDefinition(
      name: name,
      description: "Test tool \(name)",
      inputSchema: ["type": .string("object")]
    )
  }

  static func request(
    runID: AgentRunID = AgentRunID(),
    messages: [Message] = [Message(role: .user, content: [.text("hello")])],
    options: InferenceOptions = InferenceOptions(),
    toolChoice: ToolChoice = .automatic,
    workingDirectory: URL? = nil
  ) -> AgentRunRequest {
    AgentRunRequest(
      runID: runID,
      modelID: modelID,
      initialMessages: messages,
      options: options,
      toolChoice: toolChoice,
      workingDirectory: workingDirectory
    )
  }

  static func textEvents(
    _ text: String = "done",
    responseID: String? = "response-1",
    usage: InferenceUsage? = nil
  ) -> [InferenceStreamEvent] {
    var events: [InferenceStreamEvent] = [
      .started(providerResponseID: responseID),
      .textDelta(text),
    ]
    if let usage {
      events.append(.usage(usage))
    }
    events.append(.completed(.stop))
    return events
  }

  static func toolEvents(
    _ calls: [ToolCall],
    leadingText: String? = nil,
    trailingText: String? = nil
  ) -> [InferenceStreamEvent] {
    var events: [InferenceStreamEvent] = [.started(providerResponseID: "tool-response")]
    if let leadingText {
      events.append(.textDelta(leadingText))
    }
    events.append(contentsOf: calls.map(InferenceStreamEvent.toolCall))
    if let trailingText {
      events.append(.textDelta(trailingText))
    }
    events.append(.completed(.toolCalls))
    return events
  }

  static func runtime(
    provider: ScriptedInferenceProvider,
    executor: ScriptedToolExecutor,
    authorization: ScriptedAuthorizationProvider = ScriptedAuthorizationProvider(),
    journal: RecordingEventJournal = RecordingEventJournal(),
    configuration: AgentRuntimeConfiguration = AgentRuntimeConfiguration()
  ) -> AgentRuntime {
    AgentRuntime(
      inferenceProvider: provider,
      toolExecutor: executor,
      authorizationProvider: authorization,
      journal: journal,
      configuration: configuration
    )
  }
}
