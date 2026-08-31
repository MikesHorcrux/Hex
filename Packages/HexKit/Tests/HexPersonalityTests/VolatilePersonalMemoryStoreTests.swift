import Foundation
import HexPersonality
import Testing

@Suite("Volatile personal memory store")
struct VolatilePersonalMemoryStoreTests {
  @Test
  func searchesDeterministicallyAndReplacesByIdentity() async throws {
    let scope = try PersonalMemoryScope(rawValue: "mike.hex")
    let store = try VolatilePersonalMemoryStore(
      maximumRecords: 4,
      maximumEncodedBytes: 8_192
    )
    let old = try record(
      scope: scope,
      id: "swift",
      kind: .preference,
      text: "Mike likes Swift examples.",
      updatedAt: 10
    )
    let pinned = try record(
      scope: scope,
      id: "mac",
      kind: .projectContext,
      text: "Hex lives on Mike's Mac.",
      updatedAt: 5,
      isPinned: true
    )
    try await store.save(old)
    try await store.save(pinned)

    let replacement = try record(
      scope: scope,
      id: "swift",
      kind: .preference,
      text: "Mike prefers technical Swift examples.",
      updatedAt: 20
    )
    try await store.save(replacement)

    #expect(
      try await store.memories(matching: PersonalMemoryQuery(scope: scope, limit: 4)) == [
        pinned,
        replacement,
      ])
    #expect(
      try await store.memories(
        matching: PersonalMemoryQuery(
          scope: scope,
          text: "TECHNICAL swift",
          kinds: [.preference],
          limit: 2
        )
      ) == [replacement]
    )
  }

  @Test
  func capacityFailureDoesNotPartiallyMutateStore() async throws {
    let scope = try PersonalMemoryScope(rawValue: "mike.hex")
    let store = try VolatilePersonalMemoryStore(
      maximumRecords: 1,
      maximumEncodedBytes: 8_192
    )
    let first = try record(
      scope: scope,
      id: "first",
      kind: .fact,
      text: "First",
      updatedAt: 1
    )
    let second = try record(
      scope: scope,
      id: "second",
      kind: .fact,
      text: "Second",
      updatedAt: 2
    )
    try await store.save(first)

    do {
      try await store.save(second)
      Issue.record("Expected capacityExceeded.")
    } catch PersonalMemoryStoreError.capacityExceeded {
      // Expected.
    } catch {
      Issue.record("Expected capacityExceeded, received: \(error)")
    }

    #expect(
      try await store.memories(matching: PersonalMemoryQuery(scope: scope, limit: 2)) == [first])
  }

  @Test
  func removalIsExplicitAndIdempotent() async throws {
    let scope = try PersonalMemoryScope(rawValue: "mike.hex")
    let store = try VolatilePersonalMemoryStore()
    let record = try record(
      scope: scope,
      id: "remove",
      kind: .fact,
      text: "Remove me",
      updatedAt: 1
    )
    try await store.save(record)

    #expect(try await store.remove(id: record.id, scope: scope))
    #expect(try await !store.remove(id: record.id, scope: scope))
    #expect(
      try await store.memories(matching: PersonalMemoryQuery(scope: scope, limit: 1)).isEmpty)
  }

  @Test
  func staleAndOversizedReplacementsDoNotMutateStore() async throws {
    let scope = try PersonalMemoryScope(rawValue: "mike.hex")
    let original = try record(
      scope: scope,
      id: "stable",
      kind: .fact,
      text: "Keep this value.",
      updatedAt: 10
    )
    let encodedBytes = try JSONEncoder().encode(original).count
    let store = try VolatilePersonalMemoryStore(
      maximumRecords: 1,
      maximumEncodedBytes: encodedBytes + 8
    )
    try await store.save(original)

    let stale = try record(
      scope: scope,
      id: "stable",
      kind: .fact,
      text: "Stale value.",
      updatedAt: 9
    )
    await #expect(throws: PersonalMemoryStoreError.staleUpdate) {
      try await store.save(stale)
    }

    let conflicting = try record(
      scope: scope,
      id: "stable",
      kind: .fact,
      text: "Conflicting same-version value.",
      updatedAt: 10
    )
    await #expect(throws: PersonalMemoryStoreError.staleUpdate) {
      try await store.save(conflicting)
    }

    try await store.save(original)

    let oversized = try record(
      scope: scope,
      id: "stable",
      kind: .fact,
      text: "This replacement is deliberately larger than the configured budget.",
      updatedAt: 11
    )
    await #expect(throws: PersonalMemoryStoreError.byteLimitExceeded) {
      try await store.save(oversized)
    }

    #expect(
      try await store.memories(matching: PersonalMemoryQuery(scope: scope, limit: 1)) == [
        original
      ])
  }

  @Test
  func cancelledOperationsDoNotMutateStore() async throws {
    let scope = try PersonalMemoryScope(rawValue: "mike.hex")
    let store = try VolatilePersonalMemoryStore()
    let value = try record(
      scope: scope,
      id: "cancelled",
      kind: .fact,
      text: "Never saved",
      updatedAt: 1
    )
    let task = Task {
      withUnsafeCurrentTask { currentTask in
        currentTask?.cancel()
      }
      try await store.save(value)
    }

    await #expect(throws: CancellationError.self) {
      try await task.value
    }
    #expect(
      try await store.memories(matching: PersonalMemoryQuery(scope: scope, limit: 1)).isEmpty)
  }

  @Test
  func isolatesIdenticalMemoryIDsAcrossScopes() async throws {
    let primaryScope = try PersonalMemoryScope(rawValue: "mike.hex")
    let secondaryScope = try PersonalMemoryScope(rawValue: "other.hex")
    let store = try VolatilePersonalMemoryStore()
    let primary = try record(
      scope: primaryScope,
      id: "shared-id",
      kind: .fact,
      text: "Primary private memory.",
      updatedAt: 1
    )
    let secondary = try record(
      scope: secondaryScope,
      id: "shared-id",
      kind: .fact,
      text: "Secondary private memory.",
      updatedAt: 1
    )
    try await store.save(primary)
    try await store.save(secondary)

    #expect(
      try await store.memories(
        matching: PersonalMemoryQuery(scope: primaryScope, limit: 2)
      ) == [primary]
    )
    #expect(
      try await store.memories(
        matching: PersonalMemoryQuery(scope: secondaryScope, limit: 2)
      ) == [secondary]
    )

    #expect(try await store.remove(id: primary.id, scope: primaryScope))
    #expect(
      try await store.memories(
        matching: PersonalMemoryQuery(scope: primaryScope, limit: 2)
      ).isEmpty
    )
    #expect(
      try await store.memories(
        matching: PersonalMemoryQuery(scope: secondaryScope, limit: 2)
      ) == [secondary]
    )
  }

  private func record(
    scope: PersonalMemoryScope,
    id: String,
    kind: PersonalMemoryKind,
    text: String,
    updatedAt: TimeInterval,
    isPinned: Bool = false
  ) throws -> PersonalMemoryRecord {
    try PersonalMemoryRecord(
      scope: scope,
      id: PersonalMemoryID(rawValue: id),
      kind: kind,
      text: text,
      source: .explicitUserStatement,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: updatedAt),
      isPinned: isPinned
    )
  }
}
