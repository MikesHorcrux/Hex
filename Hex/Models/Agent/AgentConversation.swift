import Foundation
import HexCore

nonisolated struct AgentConversation: Codable, Equatable, Identifiable, Sendable {
  static let defaultTitle = "New conversation"
  static let maximumTitleBytes = 256

  let id: UUID
  var title: String
  let createdAt: Date
  var updatedAt: Date
  var transcript: [ConversationItem]
  var composerSelection: AgentComposerSelection?
  /// Missing on legacy archives. Nil never claims that lost native tool history was recovered.
  var history: AgentConversationHistory?
  /// Absent from old archives: a historical watermark alone never claims restart recoverability.
  var pendingRun: AgentConversationRunCheckpoint?
  /// Exact output references survive compaction and tool completion without a following message.
  /// Nil preserves the canonical shape of archives created before the output catalog existed.
  var artifactInventory: [ArtifactReference]?
  /// Optional fields keep canonical legacy archive bytes unchanged when absent.
  var archivedAt: Date?
  var isTitleExplicit: Bool?

  var isArchived: Bool { archivedAt != nil }

  init(
    id: UUID = UUID(),
    title: String = AgentConversation.defaultTitle,
    createdAt: Date = Date(),
    updatedAt: Date? = nil,
    transcript: [ConversationItem] = [],
    composerSelection: AgentComposerSelection? = nil,
    history: AgentConversationHistory? = nil,
    pendingRun: AgentConversationRunCheckpoint? = nil,
    artifactInventory: [ArtifactReference]? = nil,
    archivedAt: Date? = nil,
    isTitleExplicit: Bool? = nil
  ) {
    self.id = id
    self.title = title
    self.createdAt = createdAt
    self.updatedAt = updatedAt ?? createdAt
    self.transcript = transcript
    self.composerSelection = composerSelection
    self.history = history
    self.pendingRun = pendingRun
    self.artifactInventory = artifactInventory
    self.archivedAt = archivedAt
    self.isTitleExplicit = isTitleExplicit
  }

  mutating func recordPrompt(_ prompt: String, at date: Date = Date()) {
    if isTitleExplicit != true, title == Self.defaultTitle {
      title = Self.title(for: prompt)
    }
    updatedAt = max(date, createdAt)
  }

  nonisolated static func isValidExplicitTitle(_ title: String) -> Bool {
    !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && title.utf8.count <= maximumTitleBytes
      && !title.unicodeScalars.contains {
        CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
      }
  }

  static func title(for prompt: String) -> String {
    let normalized =
      prompt
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
    guard !normalized.isEmpty else {
      return defaultTitle
    }
    let limit = 48
    if normalized.count <= limit {
      return normalized
    }
    return String(normalized.prefix(limit - 1)) + "…"
  }
}
