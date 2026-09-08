import Foundation

/// Loads the current profile, retrieves scope-local memories, and delegates safe prompt assembly.
///
/// The service never merges memory text into the policy message. `PersonalityContextComposer`
/// remains the sole owner of the policy/data separation and escaping boundary.
public struct PersonalityContextService: Sendable {
  private let profileStore: any PersonalityProfileStore
  private let memoryStore: any PersonalMemoryStore
  private let composer: PersonalityContextComposer

  public init(
    profileStore: any PersonalityProfileStore,
    memoryStore: any PersonalMemoryStore,
    composer: PersonalityContextComposer
  ) {
    self.profileStore = profileStore
    self.memoryStore = memoryStore
    self.composer = composer
  }

  public init(
    profileStore: any PersonalityProfileStore,
    memoryStore: any PersonalMemoryStore
  ) throws {
    self.init(
      profileStore: profileStore,
      memoryStore: memoryStore,
      composer: try PersonalityContextComposer()
    )
  }

  /// Assembles context using a caller-provided, already validated memory query.
  public func assemble(query: PersonalMemoryQuery) async throws -> PersonalityContext {
    try Task.checkCancellation()
    guard let profile = try await profileStore.load() else {
      throw PersonalityContextServiceError.profileUnavailable
    }
    try Task.checkCancellation()
    let memories = try await memoryStore.memories(matching: query)
    try Task.checkCancellation()
    return try composer.compose(
      scope: query.scope,
      profile: profile,
      memories: memories
    )
  }

  /// Assembles context for a scope, optionally selecting memories relevant to the supplied text.
  public func assemble(
    scope: PersonalMemoryScope,
    relevantText: String? = nil,
    kinds: Set<PersonalMemoryKind> = [],
    limit: Int = 64
  ) async throws -> PersonalityContext {
    let query = try PersonalMemoryQuery(
      scope: scope,
      text: relevantText,
      kinds: kinds,
      limit: limit
    )
    return try await assemble(query: query)
  }
}
