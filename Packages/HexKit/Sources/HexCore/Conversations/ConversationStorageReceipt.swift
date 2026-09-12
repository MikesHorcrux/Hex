import Foundation

public struct ConversationStorageReceipt: Codable, Equatable, Sendable {
  public let id: UUID
  public let revision: Int64
  public init(id: UUID, revision: Int64) {
    self.id = id
    self.revision = revision
  }
}
