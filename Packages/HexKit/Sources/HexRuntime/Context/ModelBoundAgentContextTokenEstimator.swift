import HexCore

/// Binds one request's provider/model identity without shared mutable estimator state.
struct ModelBoundAgentContextTokenEstimator: AgentContextTokenEstimating {
  let base: any AgentContextTokenEstimating
  let model: ModelDescriptor

  func estimateTokens(in message: Message) throws -> Int {
    try base.estimateTokens(in: message, model: model)
  }

  func estimateTokens(in tool: ToolDefinition) throws -> Int {
    try base.estimateTokens(in: tool, model: model)
  }
}
