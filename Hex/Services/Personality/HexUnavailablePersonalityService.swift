import HexPersonality

struct HexUnavailablePersonalityService: HexPersonalityServicing {
  func loadProfile() async throws -> PersonalityProfile? {
    throw HexPersonalityServiceError.unavailable
  }

  func saveProfile(_ profile: PersonalityProfile) async throws {
    throw HexPersonalityServiceError.unavailable
  }

  func listMemories(
    scope: PersonalMemoryScope,
    text: String?,
    limit: Int
  ) async throws -> [PersonalMemoryRecord] {
    throw HexPersonalityServiceError.unavailable
  }

  func saveMemory(_ record: PersonalMemoryRecord) async throws {
    throw HexPersonalityServiceError.unavailable
  }

  @discardableResult
  func deleteMemory(
    id: PersonalMemoryID,
    scope: PersonalMemoryScope
  ) async throws -> Bool {
    throw HexPersonalityServiceError.unavailable
  }
}
