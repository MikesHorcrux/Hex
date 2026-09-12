import Foundation

public struct ConversationStorageWrite: Codable, Equatable, Sendable {
  public let operationID: UUID
  public let document: ConversationStorageDocument
  public let entries: [ConversationStorageEntry]
  /// False appends evidence without resending or replacing an existing working checkpoint.
  public let updatesCheckpoint: Bool
  /// Non-nil only while importing an unpublished legacy archive.
  public let importID: String?

  public init(
    operationID: UUID = UUID(), document: ConversationStorageDocument,
    entries: [ConversationStorageEntry],
    importID: String? = nil, updatesCheckpoint: Bool = true
  ) {
    self.operationID = operationID
    self.document = document
    self.entries = entries
    self.importID = importID
    self.updatesCheckpoint = updatesCheckpoint
  }
}
