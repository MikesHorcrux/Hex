import CryptoKit
import Foundation
import HexCore

extension AgentSQLiteConversationStore {
  func importLegacyArchive() async throws {
    // The bounded legacy reader verifies ownership, symlinks and canonical bytes. It never rewrites
    // or removes the source: conversations.json remains the recovery copy after publication.
    guard let legacy else { throw ConversationStorageRequest.Failure.unavailable }
    let archive =
      try await legacy.load()
      ?? AgentConversationArchive(selectedConversationID: nil, conversations: [])
    let source = try Self.encode(archive)
    let fingerprint = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
    var receipts: [ConversationStorageRequest.Receipt] = []
    for original in archive.conversations {
      var conversation = original
      conversation.history = original.resolvedHistory()
      try await saveConversation(conversation, importID: fingerprint)
      guard
        let document = try await storage.conversationStorage(.read(conversation.id)).documents
          .first,
        document.state == (try Self.state(for: conversation))
      else {
        throw ConversationStorageRequest.Failure.invalidRequest
      }
      // Read every imported record back through bounded pages, comparing identities and exact JSON.
      // An interrupted import stays invisible and can resume using the same fingerprint.
      let expected = Dictionary(
        uniqueKeysWithValues: try Self.entries(for: conversation).map { ($0.id, $0) })
      var verified = Set<String>()
      for kind in [ConversationStorageRequest.Entry.Kind.display, .message, .exchange, .compaction]
      {
        var before: Int64?
        repeat {
          let page = try await storage.conversationStorage(
            .entries(
              conversation.id, kind: kind,
              before: before, limit: 100, revision: document.revision))
          for entry in page.entries {
            guard let source = expected[entry.id], source.payload == entry.payload,
              source.searchText == entry.searchText, verified.insert(entry.id).inserted
            else {
              throw ConversationStorageRequest.Failure.invalidRequest
            }
          }
          before = page.before
        } while before != nil
      }
      guard verified == Set(expected.keys) else {
        throw ConversationStorageRequest.Failure.invalidRequest
      }
      receipts.append(.init(id: conversation.id, revision: document.revision))
    }
    _ = try await storage.conversationStorage(
      .publishImport(
        fingerprint, documents: receipts,
        selected: archive.selectedConversationID))
    fingerprints.removeAll()
  }
}
