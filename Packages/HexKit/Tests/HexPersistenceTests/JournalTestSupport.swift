import Darwin
import Foundation
import HexCore

@testable import HexPersistence

enum JournalTestSupport {
  static func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager().temporaryDirectory.appendingPathComponent(
      "hex-journal-tests-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager().createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: nil
    )
    return directory
  }

  static func removeTemporaryDirectory(_ directory: URL) {
    try? FileManager().removeItem(at: directory)
  }

  static func databaseURL(in directory: URL) -> URL {
    directory.appendingPathComponent("journal.sqlite", isDirectory: false)
  }

  static func configuration(
    in directory: URL,
    maximumReadLimit: Int = 100
  ) -> SQLiteAgentEventJournalConfiguration {
    SQLiteAgentEventJournalConfiguration(
      databaseURL: databaseURL(in: directory),
      maximumReadLimit: maximumReadLimit
    )
  }

  static func withConnection<Value>(
    at databaseURL: URL,
    _ body: (SQLiteConnection) throws -> Value
  ) throws -> Value {
    let connection = try makeConnection(at: databaseURL)
    do {
      let value = try body(connection)
      try connection.close()
      return value
    } catch {
      do {
        try connection.close()
      } catch {
        // The fixture operation error remains the useful test failure.
      }
      throw error
    }
  }

  static func makeConnection(
    at databaseURL: URL,
    busyTimeoutMilliseconds: Int = 5_000
  ) throws -> SQLiteConnection {
    try SQLiteConnection(
      databaseURL: canonicalDatabaseURL(databaseURL),
      busyTimeoutMilliseconds: busyTimeoutMilliseconds
    )
  }

  static func fileStatus(at url: URL) throws -> stat {
    var fileStatus = stat()
    guard lstat(url.path, &fileStatus) == 0 else {
      throw SQLiteAgentEventJournalError.database(
        code: Int32(errno),
        message: String(cString: strerror(errno))
      )
    }
    return fileStatus
  }

  private static func canonicalDatabaseURL(_ databaseURL: URL) throws -> URL {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let parentPath = databaseURL.deletingLastPathComponent().path
    let result = parentPath.withCString { pathPointer in
      realpath(pathPointer, &buffer)
    }
    guard result != nil else {
      throw SQLiteAgentEventJournalError.database(
        code: Int32(errno),
        message: String(cString: strerror(errno))
      )
    }
    let codeUnits = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return URL(
      fileURLWithPath: String(decoding: codeUnits, as: UTF8.self),
      isDirectory: true
    ).appendingPathComponent(databaseURL.lastPathComponent, isDirectory: false)
  }

  static func execute(_ sql: String, at databaseURL: URL) throws {
    try withConnection(at: databaseURL) { connection in
      try connection.execute(sql)
    }
  }

  static func userVersion(at databaseURL: URL) throws -> Int {
    try withConnection(at: databaseURL) { connection in
      Int(try connection.scalarInt64("PRAGMA user_version"))
    }
  }

  static func scalarInt64(_ sql: String, at databaseURL: URL) throws -> Int64 {
    try withConnection(at: databaseURL) { connection in
      try connection.scalarInt64(sql)
    }
  }

  static func tableExists(_ name: String, at databaseURL: URL) throws -> Bool {
    try withConnection(at: databaseURL) { connection in
      let statement = try connection.prepare(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?"
      )
      try statement.bind(name, at: 1)
      guard try statement.step() == .row else {
        return false
      }
      return try statement.columnInt64(at: 0) == 1
    }
  }

  static func createVersionOneFixture(
    at databaseURL: URL
  ) throws -> (runID: AgentRunID, events: [AgentEvent]) {
    let runID = AgentRunID()
    let events: [AgentEvent] = [.runStarted, .runCompleted]
    try withConnection(at: databaseURL) { connection in
      try connection.withImmediateTransaction {
        try connection.execute(
          """
          CREATE TABLE runs (
            run_id TEXT PRIMARY KEY NOT NULL,
            next_sequence INTEGER NOT NULL,
            terminal_sequence INTEGER,
            created_at_us INTEGER NOT NULL,
            updated_at_us INTEGER NOT NULL
          )
          """
        )
        try connection.execute(
          """
          CREATE TABLE event_records (
            event_id TEXT NOT NULL UNIQUE,
            run_id TEXT NOT NULL,
            sequence INTEGER NOT NULL,
            timestamp_us INTEGER NOT NULL,
            record_schema_version INTEGER NOT NULL,
            kind TEXT NOT NULL,
            tool_call_id TEXT,
            payload BLOB NOT NULL,
            PRIMARY KEY (run_id, sequence),
            FOREIGN KEY (run_id) REFERENCES runs(run_id) ON DELETE CASCADE
          )
          """
        )
        try connection.execute("PRAGMA user_version = 1")

        let insertRun = try connection.prepare(
          """
          INSERT INTO runs (
            run_id, next_sequence, terminal_sequence, created_at_us, updated_at_us
          ) VALUES (?, 3, 2, 1, 2)
          """
        )
        try insertRun.bind(runID.description, at: 1)
        _ = try insertRun.step()

        for (offset, event) in events.enumerated() {
          let sequence = Int64(offset + 1)
          let insertEvent = try connection.prepare(
            """
            INSERT INTO event_records (
              event_id, run_id, sequence, timestamp_us, record_schema_version, kind,
              tool_call_id, payload
            ) VALUES (?, ?, ?, ?, 1, ?, NULL, ?)
            """
          )
          try insertEvent.bind(AgentEventID().description, at: 1)
          try insertEvent.bind(runID.description, at: 2)
          try insertEvent.bind(sequence, at: 3)
          try insertEvent.bind(sequence, at: 4)
          try insertEvent.bind(event.journalKind, at: 5)
          try insertEvent.bind(AgentEventCodec.encode(event: event), at: 6)
          _ = try insertEvent.step()
        }
      }
    }
    return (runID, events)
  }

  static func createVersionTwoFixture(
    at databaseURL: URL
  ) throws -> (runID: AgentRunID, events: [AgentEvent]) {
    let fixture = try createVersionOneFixture(at: databaseURL)
    try withConnection(at: databaseURL) { connection in
      try connection.execute(
        """
        CREATE TABLE journal_checkpoints (
          run_id TEXT NOT NULL,
          through_sequence INTEGER NOT NULL,
          created_at_us INTEGER NOT NULL,
          checkpoint_schema_version INTEGER NOT NULL,
          snapshot BLOB NOT NULL,
          PRIMARY KEY (run_id, through_sequence),
          FOREIGN KEY (run_id) REFERENCES runs(run_id) ON DELETE CASCADE
        );
        CREATE INDEX event_records_run_kind_tool_call_idx
        ON event_records (run_id, kind, tool_call_id);
        PRAGMA user_version = 2;
        """
      )
    }
    return fixture
  }
}
