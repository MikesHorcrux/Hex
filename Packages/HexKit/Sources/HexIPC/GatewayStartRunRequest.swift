import Foundation
import HexCore

public struct GatewayStartRunRequest: Codable, Equatable, Sendable {
  public let runID: AgentRunID
  public let modelID: ModelID
  public let initialMessages: [Message]
  public let options: InferenceOptions
  public let toolChoice: ToolChoice

  /// A requested working-directory identity, not a grant of filesystem authority. The same-process
  /// transport remains constrained by the app sandbox and does not expand file access.
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
