public struct AgentRuntimeConfiguration: Codable, Equatable, Sendable {
  public let budget: AgentRunBudget
  public let context: AgentContextConfiguration
  public let toolRouting: AgentToolRoutingConfiguration

  public init(
    budget: AgentRunBudget = .standard,
    context: AgentContextConfiguration = AgentContextConfiguration(),
    toolRouting: AgentToolRoutingConfiguration = .disabled
  ) {
    self.budget = budget
    self.context = context
    self.toolRouting = toolRouting
  }

  private enum CodingKeys: String, CodingKey { case budget, context, toolRouting }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    budget = try container.decode(AgentRunBudget.self, forKey: .budget)
    context =
      try container.decodeIfPresent(AgentContextConfiguration.self, forKey: .context)
      ?? AgentContextConfiguration()
    toolRouting =
      try container.decodeIfPresent(AgentToolRoutingConfiguration.self, forKey: .toolRouting)
      ?? .disabled
    try context.validate()
    try toolRouting.validate()
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(budget, forKey: .budget)
    if context != AgentContextConfiguration() { try container.encode(context, forKey: .context) }
    if toolRouting != .disabled {
      try container.encode(toolRouting, forKey: .toolRouting)
    }
  }
}
