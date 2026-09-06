public struct AgentRuntimeConfiguration: Codable, Equatable, Sendable {
  public let budget: AgentRunBudget
  public let context: AgentContextConfiguration

  public init(
    budget: AgentRunBudget = .standard,
    context: AgentContextConfiguration = AgentContextConfiguration()
  ) {
    self.budget = budget
    self.context = context
  }

  private enum CodingKeys: String, CodingKey { case budget, context }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    budget = try container.decode(AgentRunBudget.self, forKey: .budget)
    context =
      try container.decodeIfPresent(AgentContextConfiguration.self, forKey: .context)
      ?? AgentContextConfiguration()
    try context.validate()
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(budget, forKey: .budget)
    if context != AgentContextConfiguration() { try container.encode(context, forKey: .context) }
  }
}
