import Foundation

public struct WorkspacePatchReceipt: Codable, Equatable, Sendable {
  public let id: String
  public let scope: ProcessSessionScope
  public let runID: AgentRunID
  public let callID: ToolCallID
  public let digest: Data
  public var state = "pending"
  public var reconciliationID: UUID?
  public var files: [WorkspacePatchFileReceipt]
  public var explanation = ""
  public init(
    id: String, scope: ProcessSessionScope, runID: AgentRunID, callID: ToolCallID, digest: Data,
    files: [WorkspacePatchFileReceipt]
  ) {
    self.id = id
    self.scope = scope
    self.runID = runID
    self.callID = callID
    self.digest = digest
    self.files = files
  }
}
