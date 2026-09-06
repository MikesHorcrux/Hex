/// Save completion acknowledges an atomic file replacement, not power-loss durability. An
/// implementation must not report cancellation after committing the supplied snapshot.
nonisolated protocol AgentConversationStoring: Sendable {
  func load() async throws -> AgentConversationArchive?
  func save(_ archive: AgentConversationArchive) async throws
  nonisolated func validateForPersistence(_ archive: AgentConversationArchive) throws
}
