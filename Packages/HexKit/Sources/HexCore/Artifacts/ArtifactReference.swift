import Foundation

/// A reference to immutable, locally preserved output. It is data, never permission to execute or
/// read an arbitrary path. Consumers resolve it through an injected artifact reader.
public struct ArtifactReference: Codable, Equatable, Sendable {
  public let id: UUID
  public let runID: AgentRunID
  public let toolCallID: ToolCallID?
  public let mediaType: String
  public let byteCount: Int64
  public let sha256: String
  public let isComplete: Bool

  public init(
    id: UUID, runID: AgentRunID, toolCallID: ToolCallID? = nil, mediaType: String,
    byteCount: Int64, sha256: String, isComplete: Bool
  ) {
    self.id = id
    self.runID = runID
    self.toolCallID = toolCallID
    self.mediaType = mediaType
    self.byteCount = byteCount
    self.sha256 = sha256
    self.isComplete = isComplete
  }
}
