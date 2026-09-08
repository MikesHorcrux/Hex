import Foundation

/// Transactional scheduling metadata and append-retained occurrence identities. Full agent output
/// remains in the event journal; paged receipt reads never scan or deserialize all prior history.
public actor SQLiteHexHeartbeatStore: HexHeartbeatHistoryStore {
  public nonisolated let databaseURL: URL
  let files: SQLiteHeartbeatFiles
  let database: SQLiteHeartbeatConnection

  private init(databaseURL: URL) throws {
    let files = try SQLiteHeartbeatFiles(databaseURL: databaseURL)
    self.files = files
    self.databaseURL = URL(fileURLWithPath: files.path)
    database = try SQLiteHeartbeatConnection(path: files.path)
  }

  public static func open(databaseURL: URL, legacyJSONURL: URL? = nil) async throws
    -> SQLiteHexHeartbeatStore
  {
    let store = try SQLiteHexHeartbeatStore(databaseURL: databaseURL)
    do { try await store.prepare(legacyJSONURL: legacyJSONURL) } catch {
      try? await store.close()
      throw error
    }
    return store
  }

  public func close() async throws { try database.close() }

  public func load() async throws -> HexHeartbeatStoreSnapshot {
    try transaction { try readSnapshot() }
  }

  public func replace(_ snapshot: HexHeartbeatStoreSnapshot) async throws {
    try transaction { try writeSnapshot(snapshot) }
  }

  public func mutate(
    _ mutation: @Sendable (HexHeartbeatStoreSnapshot) throws -> HexHeartbeatStoreSnapshot
  ) async throws -> HexHeartbeatStoreSnapshot {
    try transaction {
      let changed = try mutation(readSnapshot())
      try writeSnapshot(changed)
      return changed
    }
  }

  func transaction<T>(_ operation: () throws -> T) throws -> T {
    try files.validate()
    return try database.transaction {
      try validateSchemaIdentity()
      let result = try operation()
      try files.validate()
      // Cancellation after this point cannot erase an acknowledged physical commit.
      return result
    }
  }

  func readSnapshot() throws -> HexHeartbeatStoreSnapshot {
    let metadata = try database.rows("SELECT is_paused FROM heartbeat_metadata WHERE singleton=1")
    guard let row = metadata.first, case .integer(let paused) = row.first, (0...1).contains(paused)
    else {
      throw SQLiteHexHeartbeatStoreError.corrupt
    }
    let rows = try database.rows(
      "SELECT id,payload FROM heartbeat_schedules ORDER BY id", maximumRows: 256)
    let schedules = try rows.map { row in
      guard row.count == 2, case .text(let id) = row[0], case .blob(let data) = row[1] else {
        throw SQLiteHexHeartbeatStoreError.corrupt
      }
      let schedule = try decode(HexHeartbeatSchedule.self, data)
      guard schedule.id.description == id else { throw SQLiteHexHeartbeatStoreError.corrupt }
      return try validate(schedule)
    }
    return HexHeartbeatStoreSnapshot(schedules: schedules, isPaused: paused == 1)
  }

  func writeSnapshot(_ snapshot: HexHeartbeatStoreSnapshot, importing: Bool = false) throws {
    guard snapshot.schedules.count <= 256 else {
      throw SQLiteHexHeartbeatStoreError.payloadTooLarge
    }
    var seen = Set<HexHeartbeatScheduleID>()
    for schedule in snapshot.schedules {
      guard seen.insert(schedule.id).inserted else { throw SQLiteHexHeartbeatStoreError.corrupt }
      _ = try validate(schedule)
      if !importing {
        let existing = try self.schedule(for: schedule.id)
        if existing == nil, try receipt(for: schedule.occurrence()) != nil {
          throw HexHeartbeatStoreError.invalidSchedule(
            "This scheduled occurrence already has a retained execution receipt. Create a new schedule identity instead of restoring an already-recorded occurrence."
          )
        }
        if let active = existing?.activeLease {
          guard schedule.activeLease == active else {
            throw HexHeartbeatStoreError.invalidLease(
              "Schedule edits cannot erase or replace an active lease. Remove the schedule without erasing its pending receipt instead."
            )
          }
        }
      }
      if !importing, let lease = schedule.activeLease {
        guard let receipt = try receipt(for: lease.occurrence), receipt.lease == lease,
          receipt.outcome == nil
        else {
          throw HexHeartbeatStoreError.invalidLease(
            "An active schedule lease must have its original pending receipt.")
        }
      }
    }
    try database.execute("DELETE FROM heartbeat_schedules")
    for schedule in snapshot.schedules { try writeSchedule(schedule) }
    try database.execute(
      "UPDATE heartbeat_metadata SET is_paused=? WHERE singleton=1",
      [.integer(snapshot.isPaused ? 1 : 0)])
  }

  func writeSchedule(_ schedule: HexHeartbeatSchedule) throws {
    try database.execute(
      "INSERT OR REPLACE INTO heartbeat_schedules(id,payload) VALUES(?,?)",
      [.text(schedule.id.description), .blob(try encode(schedule))])
  }

  func schedule(for id: HexHeartbeatScheduleID) throws -> HexHeartbeatSchedule? {
    let rows = try database.rows(
      "SELECT payload FROM heartbeat_schedules WHERE id=?", [.text(id.description)])
    guard let row = rows.first else { return nil }
    guard case .blob(let data) = row.first else { throw SQLiteHexHeartbeatStoreError.corrupt }
    let schedule = try validate(decode(HexHeartbeatSchedule.self, data))
    guard schedule.id == id else { throw SQLiteHexHeartbeatStoreError.corrupt }
    return schedule
  }

  func receipt(for occurrence: HexHeartbeatOccurrenceID) throws -> HexHeartbeatOccurrenceReceipt? {
    let rows = try database.rows(
      Self.receiptColumns + " WHERE schedule_id=? AND due_at=?",
      [
        .text(occurrence.scheduleID.description),
        .real(occurrence.dueAt.timeIntervalSinceReferenceDate),
      ])
    guard let row = rows.first else { return nil }
    let receipt = try decodeReceiptRow(row).1
    guard receipt.occurrence == occurrence else { throw SQLiteHexHeartbeatStoreError.corrupt }
    return receipt
  }

  func writeReceipt(_ receipt: HexHeartbeatOccurrenceReceipt, inserting: Bool) throws {
    _ = try validate(receipt)
    let payload = try encode(receipt, maximumBytes: 32_768)
    if inserting {
      try database.execute(
        """
        INSERT INTO heartbeat_receipts(schedule_id,due_at,lease_id,run_id,expires_at,is_terminal,payload)
        VALUES(?,?,?,?,?,?,?)
        """,
        [
          .text(receipt.occurrence.scheduleID.description),
          .real(receipt.occurrence.dueAt.timeIntervalSinceReferenceDate),
          receipt.lease.map { .text($0.leaseID.uuidString) } ?? .null,
          receipt.runID.map { .text($0.rawValue.uuidString) } ?? .null,
          receipt.lease.map { .real($0.expiresAt.timeIntervalSinceReferenceDate) } ?? .null,
          .integer(receipt.outcome == nil ? 0 : 1), .blob(payload),
        ])
    } else {
      try database.execute(
        "UPDATE heartbeat_receipts SET is_terminal=?,payload=? WHERE schedule_id=? AND due_at=?",
        [
          .integer(receipt.outcome == nil ? 0 : 1), .blob(payload),
          .text(receipt.occurrence.scheduleID.description),
          .real(receipt.occurrence.dueAt.timeIntervalSinceReferenceDate),
        ])
    }
  }

  func encode<T: Encodable>(_ value: T, maximumBytes: Int = 131_072) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    guard data.count <= maximumBytes else { throw SQLiteHexHeartbeatStoreError.payloadTooLarge }
    return data
  }

  func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
    do { return try JSONDecoder().decode(type, from: data) } catch {
      throw SQLiteHexHeartbeatStoreError.corrupt
    }
  }
}
