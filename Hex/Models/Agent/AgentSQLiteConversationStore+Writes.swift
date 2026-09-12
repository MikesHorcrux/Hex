import CryptoKit
import Foundation
import HexCore

extension AgentSQLiteConversationStore {
  func saveConversation(_ input: AgentConversation, importID: String? = nil) async throws {
    // Resolve an uncertain earlier commit with the identical operation before accepting new state.
    if let pending = pendingWrites[input.id] { try await commit(pending) }
    let previous = try await storage.conversationStorage(.read(input.id)).documents.first
    let expected = revisions[input.id] ?? (importID == nil ? 0 : previous?.revision ?? 0)
    guard (previous?.revision ?? 0) == expected else {
      throw ConversationStorageFailure.revisionConflict
    }
    revisions[input.id] = expected
    var conversation = input
    if conversation.history == nil, let existing = previous {
      conversation = try JSONDecoder().decode(AgentConversation.self, from: existing.state)
      conversation.title = input.title
      conversation.isTitleExplicit = input.isTitleExplicit ?? conversation.isTitleExplicit
      conversation.updatedAt = input.updatedAt
      conversation.archivedAt = input.archivedAt
    }
    let state = try Self.state(for: conversation)
    let all = try Self.entries(for: conversation)
    let known = fingerprints[conversation.id] ?? [:]
    let changed = all.filter { known[$0.id] != Data(SHA256.hash(data: $0.payload)) }
    var remaining = changed[...]
    // Original evidence is durable before its new checkpoint is published. A large record can
    // travel independently of a large checkpoint, so the wire bound never becomes an archive cap.
    var exists = previous != nil
    var published = false
    repeat {
      var batch: [ConversationStorageEntry] = []
      var bytes = 0
      while let entry = remaining.first {
        let cost = entry.payload.count + entry.searchText.utf8.count + 512
        if !batch.isEmpty && (bytes + cost > 512 * 1_024 || batch.count == 100) { break }
        batch.append(entry)
        bytes += cost
        remaining = remaining.dropFirst()
      }
      var document = ConversationStorageDocument(
        id: conversation.id,
        title: conversation.title, createdAt: conversation.createdAt,
        updatedAt: conversation.updatedAt,
        archivedAt: conversation.archivedAt, revision: revisions[conversation.id] ?? 0,
        state: state)
      var write = ConversationStorageWrite(
        document: document, entries: batch, importID: importID)
      let encodedBytes = try Self.encode(write).count
      published =
        remaining.isEmpty
        && encodedBytes <= ConversationStorageRequest.maximumEncodedWriteBytes
      if !published {
        document.state = try exists ? Data() : Self.emptyState(for: conversation)
        write = .init(
          document: document, entries: batch, importID: importID,
          updatesCheckpoint: !exists)
      }
      pendingWrites[conversation.id] = write
      try await commit(write)
      exists = true
    } while !remaining.isEmpty || !published
    // Bound cache memory to the current working set. Older entry identities are checked in SQLite.
    fingerprints[conversation.id] = try Self.fingerprints(for: conversation)
  }

  func commit(_ write: ConversationStorageWrite) async throws {
    let response = try await storage.conversationStorage(.write(write))
    guard let receipt = response.receipt, receipt.id == write.document.id,
      receipt.revision == write.document.revision + 1
    else {
      throw ConversationStorageFailure.invalidRequest
    }
    revisions[receipt.id] = receipt.revision
    pendingWrites.removeValue(forKey: receipt.id)
  }

  nonisolated static func emptyState(for conversation: AgentConversation) throws -> Data {
    var empty = conversation
    empty.transcript = []
    empty.history = AgentConversationHistory(contextBase: [])
    empty.pendingRun = nil
    return try encode(empty)
  }
}
