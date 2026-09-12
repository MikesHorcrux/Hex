import Foundation

public struct ConversationStorageQuery: Codable, Equatable, Sendable {
  public let search: String
  public let archived: Bool?
  public let after: ConversationStorageCursor?
  public let limit: Int
  public init(
    search: String = "", archived: Bool? = false, after: ConversationStorageCursor? = nil,
    limit: Int = 50
  ) {
    self.search = search
    self.archived = archived
    self.after = after
    self.limit = limit
  }
}
