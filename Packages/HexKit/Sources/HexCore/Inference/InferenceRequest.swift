/// A provider-neutral inference request. Core request values must never carry credentials or other
/// secrets.
public struct InferenceRequest: Identifiable, Codable, Equatable, Sendable {
  public let id: InferenceRequestID
  public let providerID: ProviderID
  public let modelID: ModelID
  /// An opaque identifier returned by the provider for the immediately preceding response.
  /// Providers that support server-managed continuation may use it instead of reconstructing
  /// provider-native reasoning and tool-call items from the neutral message history.
  public let previousProviderResponseID: String?
  public let messages: [Message]
  public let tools: [ToolDefinition]
  public let toolChoice: ToolChoice
  public let options: InferenceOptions

  public init(
    id: InferenceRequestID = InferenceRequestID(),
    providerID: ProviderID,
    modelID: ModelID,
    previousProviderResponseID: String? = nil,
    messages: [Message],
    tools: [ToolDefinition] = [],
    toolChoice: ToolChoice = .automatic,
    options: InferenceOptions = InferenceOptions()
  ) {
    self.id = id
    self.providerID = providerID
    self.modelID = modelID
    self.previousProviderResponseID = previousProviderResponseID
    self.messages = messages
    self.tools = tools
    self.toolChoice = toolChoice
    self.options = options
  }
}
