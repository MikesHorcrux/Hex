public protocol PersonalMemoryStore: Sendable {
  func save(_ record: PersonalMemoryRecord) async throws

  @discardableResult
  func remove(id: PersonalMemoryID) async throws -> Bool

  func memories(matching query: PersonalMemoryQuery) async throws -> [PersonalMemoryRecord]
}
