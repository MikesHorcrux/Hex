public struct ArtifactMetadata: Equatable, Sendable {
  public let runID: AgentRunID
  public let toolCallID: ToolCallID?
  public let mediaType: String

  public init(runID: AgentRunID, toolCallID: ToolCallID? = nil, mediaType: String) {
    self.runID = runID
    self.toolCallID = toolCallID
    self.mediaType = mediaType
  }
}
