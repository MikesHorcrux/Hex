import Foundation

public struct ConversationStorageDocument: Codable, Equatable, Sendable {
  public let id: UUID
  public var title: String
  public var createdAt: Date
  public var updatedAt: Date
  public var archivedAt: Date?
  public var revision: Int64
  /// A bounded working checkpoint. Historical originals belong in entries, never in this blob.
  public var state: Data

  public init(
    id: UUID, title: String, createdAt: Date, updatedAt: Date,
    archivedAt: Date? = nil, revision: Int64 = 0, state: Data = Data()
  ) {
    self.id = id
    self.title = title
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.archivedAt = archivedAt
    self.revision = revision
    self.state = state
  }
}
