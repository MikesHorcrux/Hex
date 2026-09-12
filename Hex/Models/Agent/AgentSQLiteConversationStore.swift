import CryptoKit
import Foundation
import HexCore

/// The app caches only loaded working documents and entry fingerprints. SQLite is opened solely
/// by the resident journal actor. A save transmits changed entries and a bounded recovery checkpoint.
actor AgentSQLiteConversationStore: AgentPagedConversationStoring {
  let storage: any ConversationStorage
  let legacy: AgentConversationStore?
  var revisions: [UUID: Int64] = [:]
  var fingerprints: [UUID: [String: Data]] = [:]
  var pendingWrites: [UUID: ConversationStorageWrite] = [:]

  init(storage: any ConversationStorage, legacy: AgentConversationStore? = .live()) {
    self.storage = storage
    self.legacy = legacy
  }

  func load() async throws -> AgentConversationArchive? {
    let status = try await storage.conversationStorage(.status)
    if status.imported == nil { try await importLegacyArchive() }
    let refreshed = try await storage.conversationStorage(.status)
    let page = try await listConversations(.init())
    var conversations = page.conversations
    if let selected = refreshed.selected {
      let conversation = try await readConversation(selected)
      if let index = conversations.firstIndex(where: { $0.id == selected }) {
        conversations[index] = conversation
      } else {
        conversations.insert(conversation, at: 0)
      }
    } else if let id = conversations.first?.id {
      conversations[0] = try await readConversation(id)
    }
    return AgentConversationArchive(
      selectedConversationID: refreshed.selected ?? conversations.first?.id,
      conversations: conversations)
  }

  /// Kept only for legacy-store protocol compatibility. Production queues submit explicit changes.
  func save(_ archive: AgentConversationArchive) async throws {
    throw ConversationStorageFailure.invalidRequest
  }

  nonisolated func validateForPersistence(_ archive: AgentConversationArchive) throws {
    for conversation in archive.conversations where conversation.history != nil {
      var runIDs = Set<AgentRunID>()
      try AgentConversationHistoryValidator.validate(
        conversation.resolvedHistory(), runIDs: &runIDs)
      guard conversation.title.utf8.count <= AgentConversation.maximumTitleBytes else {
        throw ConversationStorageFailure.invalidRequest
      }
      // Validate each record independently; the conversation's lifetime size is not an admission cap.
      for entry in try Self.entries(for: conversation) {
        guard entry.payload.count <= ConversationStorageRequest.maximumPayloadBytes else {
          throw ConversationStorageFailure.invalidRequest
        }
      }
      _ = try Self.state(for: conversation)
    }
  }

  func saveChanges(_ conversations: [AgentConversation], selected: UUID?) async throws {
    for conversation in conversations { try await saveConversation(conversation) }
    _ = try await storage.conversationStorage(.select(selected))
    fingerprints = fingerprints.filter { $0.key == selected }
  }

  func readConversation(_ id: UUID) async throws -> AgentConversation {
    guard let document = try await storage.conversationStorage(.read(id)).documents.first else {
      throw ConversationStorageFailure.invalidRequest
    }
    var conversation: AgentConversation
    if document.state == Data("{\"durableConversation\":1}".utf8) {
      conversation = AgentConversation(
        id: document.id, title: document.title,
        createdAt: document.createdAt, updatedAt: document.updatedAt, history: .init())
    } else {
      conversation = try JSONDecoder().decode(AgentConversation.self, from: document.state)
    }
    guard conversation.id == id else { throw ConversationStorageFailure.invalidRequest }
    conversation.title = document.title
    conversation.updatedAt = document.updatedAt
    conversation.archivedAt = document.archivedAt
    revisions[id] = document.revision
    let page = try await earlierTranscript(id, before: nil)
    conversation.transcript = page.items
    try validateForPersistence(.init(selectedConversationID: id, conversations: [conversation]))
    fingerprints[id] = try Self.fingerprints(for: conversation)
    return conversation
  }

  func earlierTranscript(_ id: UUID, before: Int64?) async throws
    -> (items: [ConversationItem], before: Int64?)
  {
    guard let revision = revisions[id] else {
      throw ConversationStorageFailure.invalidRequest
    }
    let page = try await storage.conversationStorage(
      .entries(
        id, kind: .display, before: before,
        limit: 50, revision: revision))
    return (
      try page.entries.map { try JSONDecoder().decode(ConversationItem.self, from: $0.payload) },
      page.before
    )
  }

  func listConversations(_ query: ConversationStorageQuery) async throws
    -> (conversations: [AgentConversation], next: ConversationStorageCursor?)
  {
    let page = try await storage.conversationStorage(.list(query))
    // Listing newer metadata cannot acknowledge a revision for a working copy we already loaded.
    for document in page.documents where revisions[document.id] == nil {
      revisions[document.id] = document.revision
    }
    return (
      page.documents.map {
        AgentConversation(
          id: $0.id, title: $0.title, createdAt: $0.createdAt,
          updatedAt: $0.updatedAt, archivedAt: $0.archivedAt)
      }, page.next
    )
  }

  func removeConversation(_ id: UUID) async throws {
    let revision: Int64
    if let value = revisions[id] {
      revision = value
    } else if let value = try await storage.conversationStorage(.read(id)).documents.first?.revision
    {
      revision = value
    } else {
      return
    }
    _ = try await storage.conversationStorage(.delete(id, revision: revision))
    revisions.removeValue(forKey: id)
    fingerprints.removeValue(forKey: id)
  }

  nonisolated static func state(for conversation: AgentConversation) throws -> Data {
    var state = conversation
    state.transcript = []
    let references = try conversation.availableArtifacts()
    state.artifactInventory = references.isEmpty ? nil : references
    var sources = conversation.artifactSources ?? []
    for exchange in conversation.resolvedHistory().exchanges {
      for message in exchange.messages {
        for part in message.content {
          if case .toolCall(let call) = part,
            references.contains(where: {
              $0.runID == exchange.runID && $0.toolCallID == call.id
            })
          {
            let source = AgentConversationArtifactSource(
              runID: exchange.runID,
              toolCallID: call.id, messageID: message.id)
            if !sources.contains(source) { sources.append(source) }
          }
        }
      }
    }
    state.artifactSources = sources.isEmpty ? nil : sources
    state.history = try AgentConversationContextProjection.workingHistory(
      in: conversation.resolvedHistory())
    let encoded = try encode(state)
    guard encoded.count <= ConversationStorageRequest.maximumPayloadBytes else {
      throw ConversationStorageFailure.invalidRequest
    }
    return encoded
  }

  nonisolated static func encode<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }

  nonisolated static func fingerprints(for conversation: AgentConversation) throws -> [String: Data]
  {
    Dictionary(
      uniqueKeysWithValues: try entries(for: conversation).map {
        ($0.id, Data(SHA256.hash(data: $0.payload)))
      })
  }

  nonisolated static func entries(for conversation: AgentConversation) throws
    -> [ConversationStorageEntry]
  {
    var entries = try conversation.transcript.map {
      ConversationStorageEntry(
        id: "display:\($0.id.uuidString)", kind: .display,
        payload: try encode($0),
        searchText: $0.text.folding(
          options: [.caseInsensitive, .diacriticInsensitive],
          locale: Locale(identifier: "en_US_POSIX")))
    }
    let history = conversation.resolvedHistory()
    for message in history.legacyMessages {
      entries.append(
        .init(id: "legacy:\(message.id)", kind: .message, payload: try encode(message)))
    }
    for exchange in history.exchanges {
      // Exchange metadata remains independently addressable. Original messages are immutable rows.
      var metadata = exchange
      metadata.messages = []
      metadata.retryOfRunID = exchange.originalRetryOfRunID ?? exchange.retryOfRunID
      metadata.originalRetryOfRunID = nil
      metadata.projectionSummaryID = nil
      entries.append(
        .init(
          id: "exchange:\(exchange.runID)", kind: .exchange,
          payload: try encode(metadata)))
      for message in exchange.messages where message.id != exchange.projectionSummaryID {
        entries.append(
          .init(
            id: "message:\(exchange.runID):\(message.id)", kind: .message,
            payload: try encode(message)))
      }
    }
    for compaction in history.compactions {
      entries.append(
        .init(
          id: "compaction:\(compaction.id)", kind: .compaction,
          payload: try encode(compaction)))
    }
    return entries
  }
}
