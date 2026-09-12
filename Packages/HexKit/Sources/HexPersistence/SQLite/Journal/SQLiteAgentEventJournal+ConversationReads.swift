import Foundation
import HexCore

extension SQLiteAgentEventJournal {
  func conversationDocument(_ id: UUID, connection: SQLiteConnection) throws
    -> ConversationStorageRequest.Document?
  {
    let statement = try connection.prepare(
      """
      SELECT id, title, created_at_us, updated_at_us, archived_at_us, revision, state
      FROM conversation_documents WHERE id = ?
      """)
    try statement.bind(id.uuidString, at: 1)
    guard try statement.step() == .row else { return nil }
    return try decodeConversationDocument(statement, includesState: true)
  }

  func decodeConversationDocument(_ statement: SQLiteStatement, includesState: Bool) throws
    -> ConversationStorageRequest.Document
  {
    guard let id = UUID(uuidString: try statement.columnText(at: 0, maximumBytes: 36)) else {
      throw ConversationStorageRequest.Failure.invalidRequest
    }
    let revision = try statement.columnInt64(at: 5)
    guard revision > 0 else { throw ConversationStorageRequest.Failure.invalidRequest }
    return ConversationStorageRequest.Document(
      id: id, title: try statement.columnText(at: 1, maximumBytes: 256),
      createdAt: AgentEventCodec.date(for: try statement.columnInt64(at: 2)),
      updatedAt: AgentEventCodec.date(for: try statement.columnInt64(at: 3)),
      archivedAt: try statement.columnOptionalInt64(at: 4).map(AgentEventCodec.date),
      revision: revision,
      state: includesState
        ? try statement.columnBlob(
          at: 6,
          maximumBytes: ConversationStorageRequest.maximumPayloadBytes) : Data())
  }

  func listConversations(
    _ query: ConversationStorageRequest.Query,
    connection: SQLiteConnection
  ) throws -> ConversationStorageRequest.Response {
    guard (1...ConversationStorageRequest.maximumPageCount).contains(query.limit),
      query.search.utf8.count <= 512
    else { throw ConversationStorageRequest.Failure.invalidRequest }
    let statement = try connection.prepare(
      """
      SELECT id, title, created_at_us, updated_at_us, archived_at_us, revision
      FROM conversation_documents d
      WHERE import_id IS NULL AND (archived_at_us IS NOT NULL) = COALESCE(?, archived_at_us IS NOT NULL)
        AND (? = '' OR instr(lower(title), ?) > 0 OR EXISTS (
          SELECT 1 FROM conversation_entries e WHERE e.conversation_id = d.id
            AND e.kind = 'display' AND instr(e.search_text, ?) > 0))
        AND (? IS NULL OR updated_at_us < ? OR (updated_at_us = ? AND id < ?))
      ORDER BY updated_at_us DESC, id DESC LIMIT ?
      """)
    if let archived = query.archived {
      try statement.bind(archived ? 1 : 0, at: 1)
    } else {
      try statement.bindNull(at: 1)
    }
    let search = query.search.folding(
      options: [.caseInsensitive, .diacriticInsensitive],
      locale: Locale(identifier: "en_US_POSIX"))
    for index: Int32 in [2, 3, 4] { try statement.bind(search, at: index) }
    if let after = query.after {
      let timestamp = try AgentEventCodec.microseconds(for: after.updatedAt)
      for index: Int32 in [5, 6, 7] { try statement.bind(timestamp, at: index) }
      try statement.bind(after.id.uuidString, at: 8)
    } else {
      for index: Int32 in [5, 6, 7, 8] { try statement.bindNull(at: index) }
    }
    try statement.bind(Int64(query.limit + 1), at: 9)
    var response = ConversationStorageRequest.Response()
    while try statement.step() == .row {
      try Task.checkCancellation()
      if response.documents.count == query.limit {
        if let last = response.documents.last {
          response.next = .init(updatedAt: last.updatedAt, id: last.id)
        }
        break
      }
      response.documents.append(try decodeConversationDocument(statement, includesState: false))
    }
    return response
  }

  func conversationEntries(
    _ id: UUID, kind: ConversationStorageRequest.Entry.Kind,
    before: Int64?, limit: Int, revision: Int64, connection: SQLiteConnection
  ) throws
    -> ConversationStorageRequest.Response
  {
    guard (1...ConversationStorageRequest.maximumPageCount).contains(limit),
      before.map({ $0 > 0 }) ?? true
    else { throw ConversationStorageRequest.Failure.invalidRequest }
    let metadata = try connection.prepare(
      "SELECT revision FROM conversation_documents WHERE id = ?")
    try metadata.bind(id.uuidString, at: 1)
    guard try metadata.step() == .row, try metadata.columnInt64(at: 0) == revision
    else { throw ConversationStorageRequest.Failure.revisionConflict }
    let statement = try connection.prepare(
      """
      SELECT id, kind, sequence, payload, search_text FROM conversation_entries
      WHERE conversation_id = ? AND kind = ? AND sequence < ?
      ORDER BY sequence DESC LIMIT ?
      """)
    try statement.bind(id.uuidString, at: 1)
    try statement.bind(kind.rawValue, at: 2)
    try statement.bind(before ?? Int64.max, at: 3)
    try statement.bind(Int64(limit + 1), at: 4)
    var response = ConversationStorageRequest.Response()
    var bytes = 0
    while try statement.step() == .row {
      try Task.checkCancellation()
      let entry = try decodeConversationEntry(statement)
      let cost = entry.payload.count + entry.searchText.utf8.count + 512
      if response.entries.count == limit
        || (!response.entries.isEmpty
          && bytes + cost > ConversationStorageRequest.maximumPageBytes)
      {
        response.before = response.entries.last?.sequence
        break
      }
      bytes += cost
      response.entries.append(entry)
    }
    response.entries.reverse()
    return response
  }

  func decodeConversationEntry(_ statement: SQLiteStatement) throws
    -> ConversationStorageRequest.Entry
  {
    guard
      let kind = ConversationStorageRequest.Entry.Kind(
        rawValue: try statement.columnText(at: 1, maximumBytes: 32))
    else {
      throw ConversationStorageRequest.Failure.invalidRequest
    }
    return .init(
      id: try statement.columnText(at: 0, maximumBytes: 256), kind: kind,
      sequence: try statement.columnInt64(at: 2),
      payload: try statement.columnBlob(
        at: 3,
        maximumBytes: ConversationStorageRequest.maximumPayloadBytes),
      searchText: try statement.columnText(at: 4, maximumBytes: 64 * 1_024))
  }

  func conversationSetting(_ key: String, connection: SQLiteConnection) throws -> String? {
    let statement = try connection.prepare("SELECT value FROM conversation_settings WHERE key = ?")
    try statement.bind(key, at: 1)
    return try statement.step() == .row
      ? statement.columnText(at: 0, maximumBytes: 256) : nil
  }

  func setConversationSetting(_ key: String, value: String, connection: SQLiteConnection) throws {
    let statement = try connection.prepare(
      """
      INSERT INTO conversation_settings (key, value) VALUES (?, ?)
      ON CONFLICT (key) DO UPDATE SET value = excluded.value
      """)
    try statement.bind(key, at: 1)
    try statement.bind(value, at: 2)
    _ = try statement.step()
  }
}
