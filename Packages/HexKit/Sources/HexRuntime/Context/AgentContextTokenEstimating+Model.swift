import HexCore

extension AgentContextTokenEstimating {
  public func estimateTokens(in message: Message, model: ModelDescriptor) throws -> Int {
    try estimateTokens(in: message)
  }

  public func estimateTokens(in tool: ToolDefinition, model: ModelDescriptor) throws -> Int {
    try estimateTokens(in: tool)
  }
}
