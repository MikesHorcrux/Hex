import Foundation
import HexCore

public struct AgentRunRequest: Identifiable, Codable, Equatable, Sendable {
  public var id: AgentRunID { runID }

  public let runID: AgentRunID
  public let modelID: ModelID
  /// Messages supplied by the gateway's trusted context layer. These participate in inference
  /// but are intentionally not journaled as user conversation items.
  public let contextMessages: [Message]
  public let initialMessages: [Message]
  public let options: InferenceOptions
  public let toolChoice: ToolChoice
  public let workingDirectory: URL?

  public init(
    runID: AgentRunID,
    modelID: ModelID,
    initialMessages: [Message],
    contextMessages: [Message] = [],
    options: InferenceOptions = InferenceOptions(),
    toolChoice: ToolChoice = .automatic,
    workingDirectory: URL? = nil
  ) {
    self.runID = runID
    self.modelID = modelID
    self.contextMessages = contextMessages
    self.initialMessages = initialMessages
    self.options = options
    self.toolChoice = toolChoice
    self.workingDirectory = workingDirectory
  }
}
