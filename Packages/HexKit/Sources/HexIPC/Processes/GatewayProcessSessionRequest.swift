import Foundation
import HexCore

public enum GatewayProcessSessionRequest: Codable, Sendable {
  case list(conversationID: UUID, before: UUID?, limit: Int)
  case read(conversationID: UUID, sessionID: UUID, offset: Int64, maximumBytes: Int)
  case changes(taskID: UUID, before: String? = nil)
  case patchFile(taskID: UUID, receiptID: String, index: Int)
  case command(conversationID: UUID, command: ProcessSessionCommand)

  public struct Response: Codable, Sendable {
    public var filePreview: WorkspaceFileChangePreview?
    public var review: WorkspaceChangesReview?
    public var sessions: [ProcessSessionRecord] = []
    public var page: ProcessSessionPage?
    public var operation: ProcessSessionOperation?
    public init() {}
  }
}
