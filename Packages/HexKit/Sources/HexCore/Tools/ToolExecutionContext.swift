import Foundation

public struct ToolExecutionContext: Codable, Equatable, Sendable {
  public let runID: AgentRunID
  public let workingDirectory: URL?

  public init(
    runID: AgentRunID,
    workingDirectory: URL? = nil
  ) {
    self.runID = runID
    self.workingDirectory = workingDirectory
  }
}
