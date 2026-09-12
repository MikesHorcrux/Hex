import Foundation

/// An owner-only, atomically replaced JSON implementation of `PersonalMemoryStore`.
///
/// Every operation reads the current snapshot while holding the file lock. This keeps separate
/// store instances from overwriting one another after a process restart or concurrent mutation.
public actor JSONPersonalMemoryStore: PersonalMemoryStore {
  public let fileURL: URL

  private let maximumRecords: Int
  private let maximumEncodedBytes: Int

  public init(
    fileURL: URL,
    maximumRecords: Int = 4_096,
    maximumEncodedBytes: Int = 16 * 1_024 * 1_024
  ) throws {
    let standardizedURL = fileURL.standardizedFileURL
    guard JSONPersonalityStoreFileSupport.isValidFileURL(standardizedURL) else {
      throw JSONPersonalMemoryStoreError.invalidFileURL
    }
    guard
      (1...100_000).contains(maximumRecords),
      (1...128 * 1_024 * 1_024).contains(maximumEncodedBytes)
    else {
      throw JSONPersonalMemoryStoreError.invalidConfiguration
    }
    self.fileURL = standardizedURL
    self.maximumRecords = maximumRecords
    self.maximumEncodedBytes = maximumEncodedBytes
  }

  public func save(_ record: PersonalMemoryRecord) async throws {
    try Task.checkCancellation()
    let fileURL = self.fileURL
    let maximumRecords = self.maximumRecords
    let maximumEncodedBytes = self.maximumEncodedBytes
    try withStoreErrorMapping {
      try JSONPersonalityStoreFileSupport.withFileLock(fileURL: fileURL) {
        let current = try readSnapshot(
          fileURL: fileURL,
          maximumEncodedBytes: maximumEncodedBytes,
          maximumRecords: maximumRecords
        )
        let key = PersonalMemoryStorageKey(scope: record.scope, id: record.id)
        var records = current.records
        if let index = records.firstIndex(where: {
          PersonalMemoryStorageKey(scope: $0.scope, id: $0.id) == key
        }) {
          let existing = records[index]
          if record == existing {
            return
          }
          guard
            record.createdAt == existing.createdAt,
            record.updatedAt > existing.updatedAt
          else {
            throw PersonalMemoryStoreError.staleUpdate
          }
          records[index] = record
        } else {
          records.append(record)
        }

        guard records.count <= maximumRecords else {
          throw PersonalMemoryStoreError.capacityExceeded
        }

        let candidate = try validatedSnapshot(
          JSONPersonalMemoryStoreSnapshot(schemaVersion: Self.schemaVersion, records: records),
          maximumRecords: maximumRecords
        )
        let data = try encode(candidate, maximumEncodedBytes: maximumEncodedBytes)
        try Task.checkCancellation()
        try JSONPersonalityStoreFileSupport.writeDurably(
          data,
          to: fileURL,
          maximumBytes: maximumEncodedBytes
        )
      }
    }
  }

  public func memory(
    id: PersonalMemoryID,
    scope: PersonalMemoryScope
  ) async throws -> PersonalMemoryRecord? {
    try Task.checkCancellation()
    let fileURL = self.fileURL
    let maximumRecords = self.maximumRecords
    let maximumEncodedBytes = self.maximumEncodedBytes
    return try withStoreErrorMapping {
      try JSONPersonalityStoreFileSupport.withFileLock(fileURL: fileURL) {
        let snapshot = try readSnapshot(
          fileURL: fileURL,
          maximumEncodedBytes: maximumEncodedBytes,
          maximumRecords: maximumRecords
        )
        return snapshot.records.first { record in
          record.scope == scope && record.id == id
        }
      }
    }
  }

  @discardableResult
  public func remove(
    id: PersonalMemoryID,
    scope: PersonalMemoryScope
  ) async throws -> Bool {
    try Task.checkCancellation()
    let fileURL = self.fileURL
    let maximumRecords = self.maximumRecords
    let maximumEncodedBytes = self.maximumEncodedBytes
    return try withStoreErrorMapping {
      try JSONPersonalityStoreFileSupport.withFileLock(fileURL: fileURL) {
        let current = try readSnapshot(
          fileURL: fileURL,
          maximumEncodedBytes: maximumEncodedBytes,
          maximumRecords: maximumRecords
        )
        let key = PersonalMemoryStorageKey(scope: scope, id: id)
        guard
          let index = current.records.firstIndex(where: {
            PersonalMemoryStorageKey(scope: $0.scope, id: $0.id) == key
          })
        else {
          return false
        }

        var records = current.records
        records.remove(at: index)
        let candidate = try validatedSnapshot(
          JSONPersonalMemoryStoreSnapshot(schemaVersion: Self.schemaVersion, records: records),
          maximumRecords: maximumRecords
        )
        let data = try encode(candidate, maximumEncodedBytes: maximumEncodedBytes)
        try Task.checkCancellation()
        try JSONPersonalityStoreFileSupport.writeDurably(
          data,
          to: fileURL,
          maximumBytes: maximumEncodedBytes
        )
        return true
      }
    }
  }

  public func memories(
    matching query: PersonalMemoryQuery
  ) async throws -> [PersonalMemoryRecord] {
    try Task.checkCancellation()
    let fileURL = self.fileURL
    let maximumRecords = self.maximumRecords
    let maximumEncodedBytes = self.maximumEncodedBytes
    return try withStoreErrorMapping {
      try JSONPersonalityStoreFileSupport.withFileLock(fileURL: fileURL) {
        let snapshot = try readSnapshot(
          fileURL: fileURL,
          maximumEncodedBytes: maximumEncodedBytes,
          maximumRecords: maximumRecords
        )
        let terms = query.text.map(Self.normalizedTerms) ?? []
        var matches: [PersonalMemoryRecord] = []
        matches.reserveCapacity(min(query.limit, snapshot.records.count))
        for record in snapshot.records {
          try Task.checkCancellation()
          guard record.scope == query.scope else {
            continue
          }
          guard query.kinds.isEmpty || query.kinds.contains(record.kind) else {
            continue
          }
          let searchable = Self.normalized(record.text)
          guard terms.allSatisfy(searchable.contains) else {
            continue
          }
          matches.append(record)
        }
        matches.sort(by: Self.memoryPrecedes)
        return Array(matches.prefix(query.limit))
      }
    }
  }

  private func withStoreErrorMapping<Result>(
    _ operation: () throws -> Result
  ) throws -> Result {
    do {
      return try operation()
    } catch let error as PersonalMemoryStoreError {
      throw error
    } catch let error as JSONPersonalMemoryStoreError {
      throw error
    } catch let error as JSONPersonalityStoreFileSupportFailure {
      switch error {
      case .invalidFileURL:
        throw JSONPersonalMemoryStoreError.invalidFileURL
      case .unsafeFile:
        throw JSONPersonalMemoryStoreError.unsafeFile
      case .lockFailure:
        throw JSONPersonalMemoryStoreError.lockFailure
      case .ioFailure:
        throw JSONPersonalMemoryStoreError.ioFailure
      case .tooLarge:
        throw JSONPersonalMemoryStoreError.recordsTooLarge
      }
    }
  }

  private func readSnapshot(
    fileURL: URL,
    maximumEncodedBytes: Int,
    maximumRecords: Int
  ) throws -> JSONPersonalMemoryStoreSnapshot {
    guard
      let data = try JSONPersonalityStoreFileSupport.readBoundedData(
        from: fileURL,
        maximumBytes: maximumEncodedBytes
      )
    else {
      return JSONPersonalMemoryStoreSnapshot(schemaVersion: Self.schemaVersion, records: [])
    }

    do {
      let snapshot = try JSONDecoder().decode(JSONPersonalMemoryStoreSnapshot.self, from: data)
      return try validatedSnapshot(snapshot, maximumRecords: maximumRecords)
    } catch let error as JSONPersonalMemoryStoreError {
      throw error
    } catch is DecodingError {
      throw JSONPersonalMemoryStoreError.malformedStore
    } catch {
      throw JSONPersonalMemoryStoreError.malformedStore
    }
  }

  private func validatedSnapshot(
    _ snapshot: JSONPersonalMemoryStoreSnapshot,
    maximumRecords: Int
  ) throws -> JSONPersonalMemoryStoreSnapshot {
    guard snapshot.schemaVersion == Self.schemaVersion else {
      throw JSONPersonalMemoryStoreError.malformedStore
    }
    guard snapshot.records.count <= maximumRecords else {
      throw JSONPersonalMemoryStoreError.recordsTooLarge
    }
    var keys = Set<PersonalMemoryStorageKey>()
    for record in snapshot.records {
      guard keys.insert(PersonalMemoryStorageKey(scope: record.scope, id: record.id)).inserted
      else {
        throw JSONPersonalMemoryStoreError.malformedStore
      }
    }
    return snapshot
  }

  private func encode(
    _ snapshot: JSONPersonalMemoryStoreSnapshot,
    maximumEncodedBytes: Int
  ) throws -> Data {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(snapshot)
      guard data.count <= maximumEncodedBytes else {
        throw PersonalMemoryStoreError.byteLimitExceeded
      }
      return data
    } catch let error as JSONPersonalMemoryStoreError {
      throw error
    } catch let error as PersonalMemoryStoreError {
      throw error
    } catch {
      throw PersonalMemoryStoreError.serializationFailed
    }
  }

  private static func normalizedTerms(_ text: String) -> [String] {
    text.split(whereSeparator: \Character.isWhitespace).map { term in
      normalized(String(term))
    }
  }

  private static func normalized(_ text: String) -> String {
    text.folding(
      options: [.caseInsensitive, .diacriticInsensitive],
      locale: Locale(identifier: "en_US_POSIX")
    )
  }

  private static func memoryPrecedes(
    _ left: PersonalMemoryRecord,
    _ right: PersonalMemoryRecord
  ) -> Bool {
    if left.isPinned != right.isPinned {
      return left.isPinned
    }
    if left.updatedAt != right.updatedAt {
      return left.updatedAt > right.updatedAt
    }
    if left.createdAt != right.createdAt {
      return left.createdAt > right.createdAt
    }
    if left.scope != right.scope {
      return left.scope.rawValue < right.scope.rawValue
    }
    return left.id.rawValue < right.id.rawValue
  }

  private static let schemaVersion = 1
}
