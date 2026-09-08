public struct AgentTaskAttempt: Codable, Equatable, Sendable, Identifiable {
  public var id: AgentRunID { runID }
  public let runID: AgentRunID
  public let number: Int
  public init(runID: AgentRunID, number: Int) {
    self.runID = runID
    self.number = number
  }
}
