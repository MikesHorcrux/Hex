import Foundation

/// Versioned documents and individually addressed history records. Payloads are JSON; indexes,
/// identity, ordering and optimistic concurrency remain typed. Limits bound one operation only.
public enum ConversationStorageRequest: Codable, Equatable, Sendable {
  public static let maximumPayloadBytes = 3 * 1_024 * 1_024
  public static let maximumPageBytes = 3 * 1_024 * 1_024
  public static let maximumPageCount = 100
  /// Leaves room for the request and base64 XPC envelope inside the gateway's 8 MiB bound.
  public static let maximumEncodedWriteBytes = 5 * 1_024 * 1_024

  case status
  case list(ConversationStorageQuery)
  case read(UUID)
  case entries(
    UUID, kind: ConversationStorageEntryKind, before: Int64?, limit: Int, revision: Int64)
  case write(ConversationStorageWrite)
  case select(UUID?)
  case delete(UUID, revision: Int64)
  case publishImport(String, documents: [ConversationStorageReceipt], selected: UUID?)

}
