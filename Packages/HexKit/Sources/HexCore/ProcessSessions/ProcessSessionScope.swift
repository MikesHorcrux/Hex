import Foundation

public struct ProcessSessionScope: Codable, Equatable, Sendable {
  public let conversationID: UUID
  public let taskID: UUID
  public let workspace: URL
  public init(conversationID: UUID, taskID: UUID, workspace: URL) {
    self.conversationID = conversationID
    self.taskID = taskID
    self.workspace = workspace
  }
}
