import Foundation
import HexPersonality
import Testing

@Suite("Volatile personal memory store")
struct VolatilePersonalMemoryStoreTests {
  @Test
  func searchesDeterministicallyAndReplacesByIdentity() async throws {
    let store = try VolatilePersonalMemoryStore(
      maximumRecords: 4,
      maximumEncodedBytes: 8_192
    )
    let old = try record(
      id: "swift",
      kind: .preference,
      text: "Mike likes Swift examples.",
      updatedAt: 10
    )
    let pinned = try record(
      id: "mac",
      kind: .projectContext,
      text: "Hex lives on Mike's Mac.",
      updatedAt: 5,
      isPinned: true
    )
    try await store.save(old)
    try await store.save(pinned)

    let replacement = try record(
      id: "swift",
      kind: .preference,
      text: "Mike prefers technical Swift examples.",
      updatedAt: 20
    )
    try await store.save(replacement)

    #expect(
      try await store.memories(matching: PersonalMemoryQuery(limit: 4)) == [
        pinned,
        replacement,
      ])
    #expect(
      try await store.memories(
        matching: PersonalMemoryQuery(text: "TECHNICAL swift", kinds: [.preference], limit: 2)
      ) == [replacement]
    )
  }

  @Test
  func capacityFailureDoesNotPartiallyMutateStore() async throws {
    let store = try VolatilePersonalMemoryStore(
      maximumRecords: 1,
      maximumEncodedBytes: 8_192
    )
    let first = try record(id: "first", kind: .fact, text: "First", updatedAt: 1)
    let second = try record(id: "second", kind: .fact, text: "Second", updatedAt: 2)
    try await store.save(first)

    do {
      try await store.save(second)
      Issue.record("Expected capacityExceeded.")
    } catch PersonalMemoryStoreError.capacityExceeded {
      // Expected.
    } catch {
      Issue.record("Expected capacityExceeded, received: \(error)")
    }

    #expect(try await store.memories(matching: PersonalMemoryQuery(limit: 2)) == [first])
  }

  @Test
  func removalIsExplicitAndIdempotent() async throws {
    let store = try VolatilePersonalMemoryStore()
    let record = try record(id: "remove", kind: .fact, text: "Remove me", updatedAt: 1)
    try await store.save(record)

    #expect(try await store.remove(id: record.id))
    #expect(try await !store.remove(id: record.id))
    #expect(try await store.memories(matching: PersonalMemoryQuery(limit: 1)).isEmpty)
  }

  @Test
  func staleAndOversizedReplacementsDoNotMutateStore() async throws {
    let original = try record(
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
      id: "stable",
      kind: .fact,
      text: "Stale value.",
      updatedAt: 9
    )
    await #expect(throws: PersonalMemoryStoreError.staleUpdate) {
      try await store.save(stale)
    }

    let conflicting = try record(
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
      id: "stable",
      kind: .fact,
      text: "This replacement is deliberately larger than the configured budget.",
      updatedAt: 11
    )
    await #expect(throws: PersonalMemoryStoreError.byteLimitExceeded) {
      try await store.save(oversized)
    }

    #expect(try await store.memories(matching: PersonalMemoryQuery(limit: 1)) == [original])
  }

  @Test
  func cancelledOperationsDoNotMutateStore() async throws {
    let store = try VolatilePersonalMemoryStore()
    let value = try record(id: "cancelled", kind: .fact, text: "Never saved", updatedAt: 1)
    let task = Task {
      withUnsafeCurrentTask { currentTask in
        currentTask?.cancel()
      }
      try await store.save(value)
    }

    await #expect(throws: CancellationError.self) {
      try await task.value
    }
    #expect(try await store.memories(matching: PersonalMemoryQuery(limit: 1)).isEmpty)
  }

  private func record(
    id: String,
    kind: PersonalMemoryKind,
    text: String,
    updatedAt: TimeInterval,
    isPinned: Bool = false
  ) throws -> PersonalMemoryRecord {
    try PersonalMemoryRecord(
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
