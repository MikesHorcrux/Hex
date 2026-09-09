import Foundation

public struct WorkspacePatchReceipt: Codable, Equatable, Sendable {
  public struct File: Codable, Equatable, Sendable {
    public let path: String
    public let before: ArtifactReference?
    public let after: ArtifactReference?
    public let expectedRevision: String?
    public var resultingRevision: String?
    public var state = "pending"
    public var tombstone: String?
    public init(
      path: String, before: ArtifactReference?, after: ArtifactReference?, expectedRevision: String?
    ) {
      self.path = path
      self.before = before
      self.after = after
      self.expectedRevision = expectedRevision
    }
  }
  public let id: String
  public let scope: ProcessSessionScope
  public let runID: AgentRunID
  public let callID: ToolCallID
  public let digest: Data
  public var state = "pending"
  public var reconciliationID: UUID?
  public var files: [File]
  public var explanation = ""
  public init(
    id: String, scope: ProcessSessionScope, runID: AgentRunID, callID: ToolCallID, digest: Data,
    files: [File]
  ) {
    self.id = id
    self.scope = scope
    self.runID = runID
    self.callID = callID
    self.digest = digest
    self.files = files
  }
}
