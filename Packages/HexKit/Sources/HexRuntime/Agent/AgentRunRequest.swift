import Foundation
import HexCore

public struct AgentRunRequest: Identifiable, Codable, Equatable, Sendable {
  public var id: AgentRunID { runID }

  public let runID: AgentRunID
  public let modelID: ModelID
  public let initialMessages: [Message]
  public let options: InferenceOptions
  public let toolChoice: ToolChoice
  public let workingDirectory: URL?

  public init(
    runID: AgentRunID,
    modelID: ModelID,
    initialMessages: [Message],
    options: InferenceOptions = InferenceOptions(),
    toolChoice: ToolChoice = .automatic,
    workingDirectory: URL? = nil
  ) {
    self.runID = runID
    self.modelID = modelID
    self.initialMessages = initialMessages
    self.options = options
    self.toolChoice = toolChoice
    self.workingDirectory = workingDirectory
  }
}
