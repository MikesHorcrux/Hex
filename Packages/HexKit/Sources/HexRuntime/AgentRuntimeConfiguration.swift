public struct AgentRuntimeConfiguration: Codable, Equatable, Sendable {
  public let budget: AgentRunBudget

  public init(budget: AgentRunBudget = .standard) {
    self.budget = budget
  }
}
