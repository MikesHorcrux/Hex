import CryptoKit
import Foundation
import HexCore

extension SQLiteAgentEventJournal: ConversationStorage {
  public func conversationStorage(_ request: ConversationStorageRequest) throws
    -> ConversationStorageResponse
  {
    try Task.checkCancellation()
    let connection = try requireConnection()
    return try withImmediateOwnedTransaction(connection: connection) {
      try SQLiteJournalMigrator.validateSchemaDefinition(
        connection: connection, maximumTextBytes: configuration.maximumTextBytes)
      try validateIntegrityDataVersion(connection: connection)
      switch request {
      case .status:
        var response = ConversationStorageResponse()
        response.selected = try conversationSetting("selected", connection: connection).flatMap(
          UUID.init)
        response.imported = try conversationSetting("legacy_import", connection: connection)
        return response
      case .list(let query): return try listConversations(query, connection: connection)
      case .read(let id):
        var response = ConversationStorageResponse()
        if let document = try conversationDocument(id, connection: connection) {
          response.documents = [document]
        }
        return response
      case .entries(let id, let kind, let before, let limit, let revision):
        return try conversationEntries(
          id, kind: kind, before: before, limit: limit,
          revision: revision, connection: connection)
      case .write(let write): return try writeConversation(write, connection: connection)
      case .select(let id):
        if let id, try conversationDocument(id, connection: connection) == nil {
          throw ConversationStorageFailure.invalidRequest
        }
        try setConversationSetting("selected", value: id?.uuidString ?? "", connection: connection)
      case .delete(let id, let revision):
        if let document = try conversationDocument(id, connection: connection) {
          guard document.revision == revision else {
            throw ConversationStorageFailure.revisionConflict
          }
          let deletion = try connection.prepare("DELETE FROM conversation_documents WHERE id = ?")
          try deletion.bind(id.uuidString, at: 1)
          _ = try deletion.step()
          if try conversationSetting("selected", connection: connection) == id.uuidString {
            try setConversationSetting("selected", value: "", connection: connection)
          }
        }
      case .publishImport(let fingerprint, let documents, let selected):
        try publishConversationImport(
          fingerprint, documents: documents, selected: selected,
          connection: connection)
      }
      return ConversationStorageResponse()
    }
  }
}
