import Darwin
import Foundation
import HexPersonality
import Testing

@Suite("JSON personal memory store")
struct JSONPersonalMemoryStoreTests {
  @Test
  func persistsQueriesAndReplacementsAcrossStoreInstances() async throws {
    let directory = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: directory)
    }
    let fileURL = directory.appendingPathComponent("memories.json", isDirectory: false)
    let scope = try PersonalMemoryScope(rawValue: "mike.hex")
    let original = try makeRecord(
      scope: scope, id: "swift", text: "Mike likes Swift.", updatedAt: 10)
    let other = try makeRecord(scope: scope, id: "mac", text: "Hex lives on a Mac.", updatedAt: 5)

    let firstStore = try JSONPersonalMemoryStore(fileURL: fileURL)
    try await firstStore.save(original)
    try await firstStore.save(other)
    let replacement = try makeRecord(
      scope: scope,
      id: "swift",
      text: "Mike prefers technical Swift examples.",
      updatedAt: 20
    )
    try await JSONPersonalMemoryStore(fileURL: fileURL).save(replacement)

    let query = try PersonalMemoryQuery(scope: scope, text: "TECHNICAL swift", limit: 2)
    #expect(
      try await JSONPersonalMemoryStore(fileURL: fileURL).memories(matching: query) == [replacement]
    )
    #expect(
      try await JSONPersonalMemoryStore(fileURL: fileURL).memories(
        matching: PersonalMemoryQuery(scope: scope, limit: 2)
      ) == [replacement, other]
    )
  }

  @Test
  func separateInstancesDoNotLoseConcurrentRecords() async throws {
    let directory = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: directory)
    }
    let fileURL = directory.appendingPathComponent("memories.json", isDirectory: false)
    let scope = try PersonalMemoryScope(rawValue: "mike.hex")
    let first = try makeRecord(scope: scope, id: "first", text: "First", updatedAt: 1)
    let second = try makeRecord(scope: scope, id: "second", text: "Second", updatedAt: 2)
    let firstStore = try JSONPersonalMemoryStore(fileURL: fileURL)
    let secondStore = try JSONPersonalMemoryStore(fileURL: fileURL)

    async let firstSave: Void = firstStore.save(first)
    async let secondSave: Void = secondStore.save(second)
    try await firstSave
    try await secondSave

    #expect(
      try await firstStore.memories(
        matching: PersonalMemoryQuery(scope: scope, limit: 2)
      ).map(\PersonalMemoryRecord.id.rawValue) == ["second", "first"]
    )
  }

  @Test
  func staleOrCapacityFailuresLeaveTheDurableSnapshotUntouched() async throws {
    let directory = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: directory)
    }
    let fileURL = directory.appendingPathComponent("memories.json", isDirectory: false)
    let scope = try PersonalMemoryScope(rawValue: "mike.hex")
    let original = try makeRecord(scope: scope, id: "stable", text: "Keep this.", updatedAt: 10)
    let store = try JSONPersonalMemoryStore(
      fileURL: fileURL,
      maximumRecords: 1,
      maximumEncodedBytes: 8_192
    )
    try await store.save(original)

    let stale = try makeRecord(scope: scope, id: "stable", text: "Stale.", updatedAt: 9)
    await #expect(throws: PersonalMemoryStoreError.staleUpdate) {
      try await store.save(stale)
    }
    let extra = try makeRecord(scope: scope, id: "extra", text: "Extra.", updatedAt: 11)
    await #expect(throws: PersonalMemoryStoreError.capacityExceeded) {
      try await store.save(extra)
    }

    #expect(
      try await store.memories(
        matching: PersonalMemoryQuery(scope: scope, limit: 2)
      ) == [original]
    )
  }

  @Test
  func malformedUnsupportedOversizedAndDuplicateSnapshotsFailClosed() async throws {
    let directory = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: directory)
    }
    let fileURL = directory.appendingPathComponent("memories.json", isDirectory: false)
    let store = try JSONPersonalMemoryStore(fileURL: fileURL, maximumEncodedBytes: 128)

    try Data(repeating: 0x20, count: 129).write(to: fileURL, options: [.atomic])
    try setPrivatePermissions(at: fileURL)
    await #expect(throws: JSONPersonalMemoryStoreError.recordsTooLarge) {
      _ = try await store.memories(
        matching: PersonalMemoryQuery(
          scope: try PersonalMemoryScope(rawValue: "mike.hex"), limit: 1)
      )
    }

    try Data(#"{"records":[],"schemaVersion":99}"#.utf8).write(to: fileURL, options: [.atomic])
    try setPrivatePermissions(at: fileURL)
    await #expect(throws: JSONPersonalMemoryStoreError.malformedStore) {
      _ = try await store.memories(
        matching: PersonalMemoryQuery(
          scope: try PersonalMemoryScope(rawValue: "mike.hex"), limit: 1)
      )
    }

    let scope = try PersonalMemoryScope(rawValue: "mike.hex")
    let record = try makeRecord(scope: scope, id: "duplicate", text: "Duplicate.", updatedAt: 1)
    let duplicateSnapshot = PersistedSnapshot(
      schemaVersion: 1,
      records: [record, record]
    )
    try JSONEncoder().encode(duplicateSnapshot).write(to: fileURL, options: [.atomic])
    try setPrivatePermissions(at: fileURL)
    let duplicateStore = try JSONPersonalMemoryStore(
      fileURL: fileURL,
      maximumEncodedBytes: 8_192
    )
    await #expect(throws: JSONPersonalMemoryStoreError.malformedStore) {
      _ = try await duplicateStore.memories(
        matching: PersonalMemoryQuery(scope: scope, limit: 1)
      )
    }
  }

  @Test
  func removalIsPersistentAndSymlinkPathsAreRejected() async throws {
    let directory = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: directory)
    }
    let fileURL = directory.appendingPathComponent("memories.json", isDirectory: false)
    let scope = try PersonalMemoryScope(rawValue: "mike.hex")
    let record = try makeRecord(scope: scope, id: "remove", text: "Remove me.", updatedAt: 1)
    let store = try JSONPersonalMemoryStore(fileURL: fileURL)
    try await store.save(record)
    #expect(try await store.remove(id: record.id, scope: scope))
    #expect(
      try await !JSONPersonalMemoryStore(fileURL: fileURL).remove(id: record.id, scope: scope))

    let linkURL = directory.appendingPathComponent("link.json", isDirectory: false)
    try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: fileURL)
    let linkStore = try JSONPersonalMemoryStore(fileURL: linkURL)
    await #expect(throws: JSONPersonalMemoryStoreError.unsafeFile) {
      _ = try await linkStore.memories(
        matching: PersonalMemoryQuery(scope: scope, limit: 1)
      )
    }
  }

  private func makeRecord(
    scope: PersonalMemoryScope,
    id: String,
    text: String,
    updatedAt: TimeInterval
  ) throws -> PersonalMemoryRecord {
    let createdAt = Date(timeIntervalSince1970: 1)
    return try PersonalMemoryRecord(
      scope: scope,
      id: PersonalMemoryID(rawValue: id),
      kind: .preference,
      text: text,
      source: .explicitUserStatement,
      createdAt: createdAt,
      updatedAt: Date(timeIntervalSince1970: updatedAt)
    )
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = try resolvedTemporaryDirectory()
      .appendingPathComponent(
        "hex-memory-store-" + UUID().uuidString,
        isDirectory: true
      )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    return directory
  }

  private func resolvedTemporaryDirectory() throws -> URL {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let resolved = FileManager.default.temporaryDirectory.path.withCString { source in
      realpath(source, &buffer) != nil
    }
    guard resolved else {
      throw JSONPersonalMemoryStoreError.ioFailure
    }
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return URL(
      fileURLWithPath: String(decoding: bytes, as: UTF8.self),
      isDirectory: true
    )
  }

  private func setPrivatePermissions(at url: URL) throws {
    guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else {
      throw JSONPersonalMemoryStoreError.ioFailure
    }
  }

  private struct PersistedSnapshot: Codable {
    let schemaVersion: Int
    let records: [PersonalMemoryRecord]
  }
}
