import HexPersonality

protocol HexPersonalityServicing: Sendable {
  func loadProfile() async throws -> PersonalityProfile?

  func saveProfile(_ profile: PersonalityProfile) async throws

  func listMemories(
    scope: PersonalMemoryScope,
    text: String?,
    limit: Int
  ) async throws -> [PersonalMemoryRecord]

  func saveMemory(_ record: PersonalMemoryRecord) async throws

  @discardableResult
  func deleteMemory(
    id: PersonalMemoryID,
    scope: PersonalMemoryScope
  ) async throws -> Bool
}
