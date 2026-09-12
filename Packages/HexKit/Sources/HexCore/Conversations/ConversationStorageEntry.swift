import Foundation

public struct ConversationStorageEntry: Codable, Equatable, Sendable {
  public let id: String
  public let kind: ConversationStorageEntryKind
  public var sequence: Int64
  public let payload: Data
  public let searchText: String

  public init(
    id: String, kind: ConversationStorageEntryKind, sequence: Int64 = 0, payload: Data,
    searchText: String = ""
  ) {
    self.id = id
    self.kind = kind
    self.sequence = sequence
    self.payload = payload
    self.searchText = searchText
  }
}
