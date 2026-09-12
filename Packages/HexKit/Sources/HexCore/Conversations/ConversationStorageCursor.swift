import Foundation

public struct ConversationStorageCursor: Codable, Equatable, Sendable {
  public let updatedAt: Date
  public let id: UUID
  public init(updatedAt: Date, id: UUID) {
    self.updatedAt = updatedAt
    self.id = id
  }
}
