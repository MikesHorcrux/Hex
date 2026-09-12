import Foundation

public struct ConversationStorageResponse: Codable, Equatable, Sendable {
  public var documents: [ConversationStorageDocument] = []
  public var entries: [ConversationStorageEntry] = []
  public var next: ConversationStorageCursor?
  public var before: Int64?
  public var selected: UUID?
  public var imported: String?
  public var receipt: ConversationStorageReceipt?
  public var failure: ConversationStorageFailure?
  public init() {}
}
