import HexPersonality

struct HexPersonalityService: HexPersonalityServicing {
  let profileStore: any PersonalityProfileStore
  let memoryStore: any PersonalMemoryStore
  let contextService: PersonalityContextService

  init(
    profileStore: any PersonalityProfileStore,
    memoryStore: any PersonalMemoryStore,
    contextService: PersonalityContextService
  ) {
    self.profileStore = profileStore
    self.memoryStore = memoryStore
    self.contextService = contextService
  }

  init(
    profileStore: any PersonalityProfileStore,
    memoryStore: any PersonalMemoryStore
  ) throws {
    self.init(
      profileStore: profileStore,
      memoryStore: memoryStore,
      contextService: try PersonalityContextService(
        profileStore: profileStore,
        memoryStore: memoryStore
      )
    )
  }

  func loadProfile() async throws -> PersonalityProfile? {
    try await profileStore.load()
  }

  func saveProfile(_ profile: PersonalityProfile) async throws {
    try await profileStore.save(profile)
  }

  func listMemories(
    scope: PersonalMemoryScope,
    text: String?,
    limit: Int
  ) async throws -> [PersonalMemoryRecord] {
    let query = try PersonalMemoryQuery(scope: scope, text: text, limit: limit)
    return try await memoryStore.memories(matching: query)
  }

  func saveMemory(_ record: PersonalMemoryRecord) async throws {
    try await memoryStore.save(record)
  }

  @discardableResult
  func deleteMemory(
    id: PersonalMemoryID,
    scope: PersonalMemoryScope
  ) async throws -> Bool {
    try await memoryStore.remove(id: id, scope: scope)
  }
}
