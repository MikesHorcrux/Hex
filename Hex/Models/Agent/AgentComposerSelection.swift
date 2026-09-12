import HexCore

/// Stored with each conversation so changing composer options never changes another conversation.
nonisolated struct AgentComposerSelection: Codable, Equatable, Sendable {
  var modelID: String?
  var effort: AgentComposerEffort
  /// Nil preserves legacy archives and inherits the resident's saved default for the next turn.
  var authorizationMode: HexAuthorizationMode? = nil
}
