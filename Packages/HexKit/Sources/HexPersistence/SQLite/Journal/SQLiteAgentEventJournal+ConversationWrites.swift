import CryptoKit
import Foundation
import HexCore

extension SQLiteAgentEventJournal {
  func writeConversation(
    _ write: ConversationStorageWrite,
    connection: SQLiteConnection
  ) throws -> ConversationStorageResponse {
    let document = write.document
    guard document.revision >= 0, document.revision < Int64.max,
      !document.title.isEmpty, document.title.utf8.count <= 256,
      document.updatedAt >= document.createdAt,
      write.importID.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true,
      write.entries.count <= ConversationStorageRequest.maximumPageCount,
      Set(write.entries.map(\.id)).count == write.entries.count
    else {
      throw ConversationStorageFailure.invalidRequest
    }
    if write.updatesCheckpoint {
      try validateConversationJSON(document.state)
    } else if !document.state.isEmpty {
      throw ConversationStorageFailure.invalidRequest
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let encoded = try encoder.encode(write)
    guard encoded.count <= ConversationStorageRequest.maximumEncodedWriteBytes else {
      throw ConversationStorageFailure.invalidRequest
    }
    let hash = Data(SHA256.hash(data: encoded))
    let lookup = try connection.prepare(
      """
      SELECT revision, next_sequence, last_operation, operation_hash, import_id
      FROM conversation_documents WHERE id = ?
      """)
    try lookup.bind(document.id.uuidString, at: 1)
    var nextSequence: Int64 = 1
    if try lookup.step() == .row {
      let revision = try lookup.columnInt64(at: 0)
      if try lookup.columnText(at: 2, maximumBytes: 36) == write.operationID.uuidString {
        guard try lookup.columnBlob(at: 3, maximumBytes: 32) == hash else {
          throw ConversationStorageFailure.operationConflict
        }
        var response = ConversationStorageResponse()
        response.receipt = .init(id: document.id, revision: revision)
        return response
      }
      guard revision == document.revision,
        try lookup.columnOptionalText(at: 4, maximumBytes: 128) == write.importID
      else {
        throw ConversationStorageFailure.revisionConflict
      }
      nextSequence = try lookup.columnInt64(at: 1)
    } else if document.revision != 0 || !write.updatesCheckpoint {
      throw ConversationStorageFailure.revisionConflict
    }
    let statement = try connection.prepare(
      """
      INSERT INTO conversation_documents
        (id, title, created_at_us, updated_at_us, archived_at_us, revision, state,
         next_sequence, last_operation, operation_hash, import_id)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT (id) DO UPDATE SET title = excluded.title,
        updated_at_us = excluded.updated_at_us, archived_at_us = excluded.archived_at_us,
        revision = excluded.revision,
        state = CASE WHEN ? THEN excluded.state ELSE conversation_documents.state END,
        last_operation = excluded.last_operation, operation_hash = excluded.operation_hash
      """)
    try statement.bind(document.id.uuidString, at: 1)
    try statement.bind(document.title, at: 2)
    try statement.bind(AgentEventCodec.microseconds(for: document.createdAt), at: 3)
    try statement.bind(AgentEventCodec.microseconds(for: document.updatedAt), at: 4)
    if let archived = document.archivedAt {
      try statement.bind(AgentEventCodec.microseconds(for: archived), at: 5)
    } else {
      try statement.bindNull(at: 5)
    }
    try statement.bind(document.revision + 1, at: 6)
    try statement.bind(document.state, at: 7)
    try statement.bind(nextSequence, at: 8)
    try statement.bind(write.operationID.uuidString, at: 9)
    try statement.bind(hash, at: 10)
    if let importID = write.importID {
      try statement.bind(importID, at: 11)
    } else {
      try statement.bindNull(at: 11)
    }
    try statement.bind(write.updatesCheckpoint ? 1 : 0, at: 12)
    _ = try statement.step()
    for entry in write.entries {
      try Task.checkCancellation()
      try writeConversationEntry(
        entry, conversationID: document.id, nextSequence: &nextSequence,
        connection: connection)
    }
    let update = try connection.prepare(
      "UPDATE conversation_documents SET next_sequence = ? WHERE id = ?")
    try update.bind(nextSequence, at: 1)
    try update.bind(document.id.uuidString, at: 2)
    _ = try update.step()
    var response = ConversationStorageResponse()
    response.receipt = .init(id: document.id, revision: document.revision + 1)
    return response
  }

  func writeConversationEntry(
    _ entry: ConversationStorageEntry, conversationID: UUID,
    nextSequence: inout Int64, connection: SQLiteConnection
  ) throws {
    guard !entry.id.isEmpty, entry.id.utf8.count <= 256, entry.searchText.utf8.count <= 64 * 1_024,
      nextSequence > 0, nextSequence < Int64.max
    else {
      throw ConversationStorageFailure.invalidRequest
    }
    try validateConversationJSON(entry.payload)
    let lookup = try connection.prepare(
      """
      SELECT id, kind, sequence, payload, search_text FROM conversation_entries
      WHERE conversation_id = ? AND id = ?
      """)
    try lookup.bind(conversationID.uuidString, at: 1)
    try lookup.bind(entry.id, at: 2)
    var sequence = nextSequence
    if try lookup.step() == .row {
      let previous = try decodeConversationEntry(lookup)
      guard previous.kind == entry.kind else {
        throw ConversationStorageFailure.immutableEntry
      }
      if previous.payload == entry.payload && previous.searchText == entry.searchText { return }
      guard entry.kind == .display || entry.kind == .exchange else {
        throw ConversationStorageFailure.immutableEntry
      }
      sequence = previous.sequence
    } else {
      nextSequence += 1
    }
    let statement = try connection.prepare(
      """
      INSERT INTO conversation_entries (conversation_id, id, kind, sequence, payload, search_text)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT (conversation_id, id) DO UPDATE
        SET payload = excluded.payload, search_text = excluded.search_text
      """)
    try statement.bind(conversationID.uuidString, at: 1)
    try statement.bind(entry.id, at: 2)
    try statement.bind(entry.kind.rawValue, at: 3)
    try statement.bind(sequence, at: 4)
    try statement.bind(entry.payload, at: 5)
    try statement.bind(entry.searchText, at: 6)
    _ = try statement.step()
  }

  func validateConversationJSON(_ data: Data) throws {
    guard !data.isEmpty, data.count <= ConversationStorageRequest.maximumPayloadBytes else {
      throw ConversationStorageFailure.invalidRequest
    }
    _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
  }

  func publishConversationImport(
    _ fingerprint: String,
    documents: [ConversationStorageReceipt], selected: UUID?,
    connection: SQLiteConnection
  ) throws {
    guard !fingerprint.isEmpty, fingerprint.utf8.count <= 128, documents.count <= 64,
      Set(documents.map(\.id)).count == documents.count,
      selected.map({ id in documents.contains(where: { $0.id == id }) }) ?? true
    else {
      throw ConversationStorageFailure.invalidRequest
    }
    if let imported = try conversationSetting("legacy_import", connection: connection) {
      guard imported == fingerprint else {
        throw ConversationStorageFailure.operationConflict
      }
      return
    }
    let lookup = try connection.prepare(
      "SELECT id, revision FROM conversation_documents WHERE import_id = ? LIMIT 65")
    try lookup.bind(fingerprint, at: 1)
    var actual: [UUID: Int64] = [:]
    while try lookup.step() == .row {
      guard let id = UUID(uuidString: try lookup.columnText(at: 0, maximumBytes: 36)) else {
        throw ConversationStorageFailure.invalidRequest
      }
      actual[id] = try lookup.columnInt64(at: 1)
    }
    guard actual == Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0.revision) }) else {
      throw ConversationStorageFailure.revisionConflict
    }
    let publication = try connection.prepare(
      "UPDATE conversation_documents SET import_id = NULL WHERE import_id = ?")
    try publication.bind(fingerprint, at: 1)
    _ = try publication.step()
    try setConversationSetting("legacy_import", value: fingerprint, connection: connection)
    try setConversationSetting(
      "selected", value: selected?.uuidString ?? "", connection: connection)
  }
}
