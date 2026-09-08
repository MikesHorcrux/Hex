public protocol PersonalMemoryStore: Sendable {
  func save(_ record: PersonalMemoryRecord) async throws

  /// Returns one record in the exact scope, if present. Implementations must never search across
  /// scopes. The default implementation keeps custom stores source-compatible while concrete
  /// stores may provide an indexed lookup.
  func memory(
    id: PersonalMemoryID,
    scope: PersonalMemoryScope
  ) async throws -> PersonalMemoryRecord?

  @discardableResult
  func remove(id: PersonalMemoryID, scope: PersonalMemoryScope) async throws -> Bool

  func memories(matching query: PersonalMemoryQuery) async throws -> [PersonalMemoryRecord]
}

extension PersonalMemoryStore {
  public func memory(
    id: PersonalMemoryID,
    scope: PersonalMemoryScope
  ) async throws -> PersonalMemoryRecord? {
    let query = try PersonalMemoryQuery(scope: scope, limit: 256)
    return try await memories(matching: query).first { record in
      record.scope == scope && record.id == id
    }
  }
}
