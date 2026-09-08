import Darwin
import Foundation

extension SQLiteHexHeartbeatStore {
  func prepare(legacyJSONURL: URL?) throws {
    try files.validate()
    let initialVersion = try database.rows("PRAGMA user_version")
    guard let initialRow = initialVersion.first,
      case .integer(let initialNumber) = initialRow.first,
      initialNumber == 0 || initialNumber == 1
    else { throw SQLiteHexHeartbeatStoreError.unsupportedSchema }
    _ = try database.rows("PRAGMA journal_mode=DELETE")
    try database.execute("PRAGMA synchronous=FULL")
    try database.execute("PRAGMA fullfsync=ON")
    try database.execute("PRAGMA foreign_keys=ON")
    try database.execute("PRAGMA trusted_schema=OFF")
    let importLock: SQLiteHeartbeatLegacyImportLock?
    if initialNumber == 0, let legacyJSONURL {
      importLock = try SQLiteHeartbeatLegacyImportLock(fileURL: legacyJSONURL)
    } else {
      importLock = nil
    }
    defer { withExtendedLifetime(importLock) {} }
    try database.transaction {
      let version = try database.rows("PRAGMA user_version")
      guard let row = version.first, case .integer(let number) = row.first else {
        throw SQLiteHexHeartbeatStoreError.corrupt
      }
      if number == 0 {
        let existing = try database.rows(
          "SELECT count(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'")
        guard let row = existing.first, case .integer(0) = row.first else {
          throw SQLiteHexHeartbeatStoreError.unsupportedSchema
        }
        // Read the legacy file before mutating anything. A malformed import is never replaced by
        // empty state, and the original JSON remains untouched even after successful migration.
        let legacy = try readLegacy(legacyJSONURL)
        try database.execute(Self.metadataSchema)
        try database.execute(Self.scheduleSchema)
        try database.execute(Self.receiptSchema)
        try database.execute(
          "CREATE INDEX heartbeat_receipts_schedule ON heartbeat_receipts(schedule_id,sequence DESC)"
        )
        try database.execute(
          "CREATE INDEX heartbeat_receipts_pending ON heartbeat_receipts(is_terminal,expires_at,sequence)"
        )
        try database.execute(
          "INSERT INTO heartbeat_metadata(singleton,store_id,is_paused,legacy_imported) VALUES(1,?,0,1)",
          [.text(UUID().uuidString)])
        try writeSnapshot(legacy, importing: true)
        for schedule in legacy.schedules {
          if let outcome = schedule.lastOutcome {
            try writeReceipt(
              HexHeartbeatOccurrenceReceipt(
                occurrence: outcome.occurrence, scheduleName: schedule.name, lease: nil,
                outcome: outcome, nextDueAtAfterCompletion: schedule.nextDueAt), inserting: true)
          }
          if let lease = schedule.activeLease {
            guard try receipt(for: lease.occurrence) == nil else {
              throw SQLiteHexHeartbeatStoreError.corrupt
            }
            try writeReceipt(
              HexHeartbeatOccurrenceReceipt(
                occurrence: lease.occurrence, scheduleName: schedule.name, lease: lease),
              inserting: true)
          }
        }
        try database.execute("PRAGMA user_version=1")
      } else if number != 1 {
        throw SQLiteHexHeartbeatStoreError.unsupportedSchema
      }
      try validateSchemaIdentity()
      try validateSchema()
      _ = try readSnapshot()
      try files.validate()
    }
    let integrity = try database.rows("PRAGMA quick_check(1)")
    guard let row = integrity.first, case .text("ok") = row.first else {
      throw SQLiteHexHeartbeatStoreError.corrupt
    }
  }

  private func readLegacy(_ url: URL?) throws -> HexHeartbeatStoreSnapshot {
    guard let url else { return HexHeartbeatStoreSnapshot() }
    guard url.isFileURL else { throw SQLiteHexHeartbeatStoreError.unavailable }
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      if errno == ENOENT { return HexHeartbeatStoreSnapshot() }
      throw SQLiteHexHeartbeatStoreError.unavailable
    }
    defer { Darwin.close(descriptor) }
    var before = stat()
    guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
      before.st_uid == geteuid(), before.st_nlink == 1, before.st_size >= 0,
      before.st_size <= 32 * 1_024 * 1_024
    else { throw SQLiteHexHeartbeatStoreError.corrupt }
    var data = Data(count: Int(before.st_size))
    let count = try data.withUnsafeMutableBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        guard let address = bytes.baseAddress else { throw SQLiteHexHeartbeatStoreError.corrupt }
        let read = Darwin.read(descriptor, address.advanced(by: offset), bytes.count - offset)
        if read > 0 {
          offset += read
        } else if read < 0, errno == EINTR {
          continue
        } else {
          throw SQLiteHexHeartbeatStoreError.corrupt
        }
      }
      return offset
    }
    var after = stat()
    var pathStatus = stat()
    guard count == data.count, fstat(descriptor, &after) == 0, lstat(url.path, &pathStatus) == 0,
      before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
      pathStatus.st_dev == after.st_dev, pathStatus.st_ino == after.st_ino
    else { throw SQLiteHexHeartbeatStoreError.corrupt }
    // Legacy had no schema field. Explicit future markers or unrecognized fields are not silently
    // discarded by synthesized Codable. Top-level input must be exactly the known legacy envelope.
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(object.keys) == ["schedules", "isPaused"]
    else { throw SQLiteHexHeartbeatStoreError.unsupportedSchema }
    let snapshot = try decode(HexHeartbeatStoreSnapshot.self, data)
    guard snapshot.schedules.count <= 256 else {
      throw SQLiteHexHeartbeatStoreError.payloadTooLarge
    }
    var seen = Set<HexHeartbeatScheduleID>()
    for schedule in snapshot.schedules {
      guard seen.insert(schedule.id).inserted else { throw SQLiteHexHeartbeatStoreError.corrupt }
      _ = try validate(schedule)
    }
    // Exact semantic re-encoding catches unknown nested fields without treating whitespace or key
    // order as corruption. No missing native/run identity is filled in during this migration.
    let reencoded = try JSONSerialization.jsonObject(
      with: encode(snapshot, maximumBytes: 32 * 1_024 * 1_024))
    guard NSDictionary(dictionary: object).isEqual(to: reencoded as? [String: Any] ?? [:]) else {
      throw SQLiteHexHeartbeatStoreError.unsupportedSchema
    }
    return snapshot
  }

  private func validateSchema() throws {
    let expected = [
      "heartbeat_metadata": Self.metadataSchema, "heartbeat_schedules": Self.scheduleSchema,
      "heartbeat_receipts": Self.receiptSchema,
    ]
    let rows = try database.rows(
      "SELECT name,sql FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
      maximumRows: 3)
    guard rows.count == expected.count else { throw SQLiteHexHeartbeatStoreError.unsupportedSchema }
    for row in rows {
      guard row.count == 2, case .text(let name) = row[0], case .text(let sql) = row[1],
        let wanted = expected[name], sql == wanted
      else { throw SQLiteHexHeartbeatStoreError.unsupportedSchema }
    }
    let triggers = try database.rows("SELECT count(*) FROM sqlite_master WHERE type='trigger'")
    guard let row = triggers.first, case .integer(0) = row.first else {
      throw SQLiteHexHeartbeatStoreError.unsupportedSchema
    }
  }

  private static let metadataSchema = """
    CREATE TABLE heartbeat_metadata(singleton INTEGER PRIMARY KEY CHECK(singleton=1),store_id TEXT NOT NULL CHECK(length(store_id)=36),is_paused INTEGER NOT NULL CHECK(is_paused IN(0,1)),legacy_imported INTEGER NOT NULL CHECK(legacy_imported=1)) STRICT
    """
  private static let scheduleSchema = """
    CREATE TABLE heartbeat_schedules(id TEXT PRIMARY KEY NOT NULL CHECK(length(id)=36),payload BLOB NOT NULL CHECK(length(payload)<=131072)) STRICT
    """
  private static let receiptSchema = """
    CREATE TABLE heartbeat_receipts(sequence INTEGER PRIMARY KEY AUTOINCREMENT,schedule_id TEXT NOT NULL CHECK(length(schedule_id)=36),due_at REAL NOT NULL,lease_id TEXT UNIQUE CHECK(lease_id IS NULL OR length(lease_id)=36),run_id TEXT UNIQUE CHECK(run_id IS NULL OR length(run_id)=36),expires_at REAL,is_terminal INTEGER NOT NULL CHECK(is_terminal IN(0,1)),payload BLOB NOT NULL CHECK(length(payload)<=32768),UNIQUE(schedule_id,due_at),CHECK(is_terminal=1 OR (lease_id IS NOT NULL AND expires_at IS NOT NULL)),CHECK(run_id IS NULL OR lease_id IS NOT NULL)) STRICT
    """
}
