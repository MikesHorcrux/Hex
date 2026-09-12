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
  case list(Query)
  case read(UUID)
  case entries(UUID, kind: Entry.Kind, before: Int64?, limit: Int, revision: Int64)
  case write(Write)
  case select(UUID?)
  case delete(UUID, revision: Int64)
  case publishImport(String, documents: [Receipt], selected: UUID?)

  public struct Document: Codable, Equatable, Sendable {
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

  public struct Entry: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case display, message, exchange, compaction }
    public let id: String
    public let kind: Kind
    public var sequence: Int64
    public let payload: Data
    public let searchText: String

    public init(
      id: String, kind: Kind, sequence: Int64 = 0, payload: Data,
      searchText: String = ""
    ) {
      self.id = id
      self.kind = kind
      self.sequence = sequence
      self.payload = payload
      self.searchText = searchText
    }
  }

  public struct Write: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let document: Document
    public let entries: [Entry]
    /// False appends evidence without resending or replacing an existing working checkpoint.
    public let updatesCheckpoint: Bool
    /// Non-nil only while importing an unpublished legacy archive.
    public let importID: String?

    public init(
      operationID: UUID = UUID(), document: Document, entries: [Entry],
      importID: String? = nil, updatesCheckpoint: Bool = true
    ) {
      self.operationID = operationID
      self.document = document
      self.entries = entries
      self.importID = importID
      self.updatesCheckpoint = updatesCheckpoint
    }
  }

  public struct Cursor: Codable, Equatable, Sendable {
    public let updatedAt: Date
    public let id: UUID
    public init(updatedAt: Date, id: UUID) {
      self.updatedAt = updatedAt
      self.id = id
    }
  }

  public struct Query: Codable, Equatable, Sendable {
    public let search: String
    public let archived: Bool?
    public let after: Cursor?
    public let limit: Int
    public init(
      search: String = "", archived: Bool? = false, after: Cursor? = nil,
      limit: Int = 50
    ) {
      self.search = search
      self.archived = archived
      self.after = after
      self.limit = limit
    }
  }

  public struct Receipt: Codable, Equatable, Sendable {
    public let id: UUID
    public let revision: Int64
    public init(id: UUID, revision: Int64) {
      self.id = id
      self.revision = revision
    }
  }

  public struct Response: Codable, Equatable, Sendable {
    public var documents: [Document] = []
    public var entries: [Entry] = []
    public var next: Cursor?
    public var before: Int64?
    public var selected: UUID?
    public var imported: String?
    public var receipt: Receipt?
    public var failure: Failure?
    public init() {}
  }

  public enum Failure: String, Codable, Error, Sendable {
    case invalidRequest, revisionConflict, operationConflict, immutableEntry, unavailable
  }
}
