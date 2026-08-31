import Foundation

public actor VolatilePersonalMemoryStore: PersonalMemoryStore {
  private let maximumRecords: Int
  private let maximumEncodedBytes: Int
  private var recordsByID: [PersonalMemoryID: PersonalMemoryRecord] = [:]
  private var encodedBytesByID: [PersonalMemoryID: Int] = [:]
  private var totalEncodedBytes = 0

  public init(
    maximumRecords: Int = 4_096,
    maximumEncodedBytes: Int = 16 * 1_024 * 1_024
  ) throws {
    guard
      (1...100_000).contains(maximumRecords),
      (1...128 * 1_024 * 1_024).contains(maximumEncodedBytes)
    else {
      throw PersonalMemoryStoreError.invalidConfiguration
    }
    self.maximumRecords = maximumRecords
    self.maximumEncodedBytes = maximumEncodedBytes
  }

  public func save(_ record: PersonalMemoryRecord) async throws {
    try Task.checkCancellation()
    if let existing = recordsByID[record.id] {
      if record == existing {
        return
      }
      guard
        record.createdAt == existing.createdAt,
        record.updatedAt > existing.updatedAt
      else {
        throw PersonalMemoryStoreError.staleUpdate
      }
    }

    let encodedBytes: Int
    do {
      encodedBytes = try JSONEncoder().encode(record).count
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw PersonalMemoryStoreError.serializationFailed
    }
    let existingBytes = encodedBytesByID[record.id] ?? 0
    let reducedTotal = totalEncodedBytes - existingBytes
    let (candidateTotal, overflowed) = reducedTotal.addingReportingOverflow(encodedBytes)
    let candidateCount = recordsByID[record.id] == nil ? recordsByID.count + 1 : recordsByID.count
    guard candidateCount <= maximumRecords else {
      throw PersonalMemoryStoreError.capacityExceeded
    }
    guard !overflowed, candidateTotal <= maximumEncodedBytes else {
      throw PersonalMemoryStoreError.byteLimitExceeded
    }
    try Task.checkCancellation()

    recordsByID[record.id] = record
    encodedBytesByID[record.id] = encodedBytes
    totalEncodedBytes = candidateTotal
  }

  @discardableResult
  public func remove(id: PersonalMemoryID) async throws -> Bool {
    try Task.checkCancellation()
    guard recordsByID.removeValue(forKey: id) != nil else {
      return false
    }
    totalEncodedBytes -= encodedBytesByID.removeValue(forKey: id) ?? 0
    return true
  }

  public func memories(
    matching query: PersonalMemoryQuery
  ) async throws -> [PersonalMemoryRecord] {
    try Task.checkCancellation()
    let terms = query.text.map(Self.normalizedTerms) ?? []
    var matches: [PersonalMemoryRecord] = []
    matches.reserveCapacity(min(query.limit, recordsByID.count))
    for record in recordsByID.values {
      try Task.checkCancellation()
      guard query.kinds.isEmpty || query.kinds.contains(record.kind) else {
        continue
      }
      let searchable = Self.normalized(record.text)
      guard terms.allSatisfy(searchable.contains) else {
        continue
      }
      matches.append(record)
    }
    matches.sort(by: Self.precedes)
    return Array(matches.prefix(query.limit))
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

  private static func precedes(
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
    return left.id.rawValue < right.id.rawValue
  }
}
