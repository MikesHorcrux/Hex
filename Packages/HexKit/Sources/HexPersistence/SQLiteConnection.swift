import Foundation
import SQLite3

final class SQLiteConnection {
  private var handle: OpaquePointer?

  init(databaseURL: URL, busyTimeoutMilliseconds: Int) throws {
    var database: OpaquePointer?
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    let result = sqlite3_open_v2(databaseURL.path, &database, flags, nil)
    guard result == SQLITE_OK, let database else {
      let message: String
      if let database {
        message = String(cString: sqlite3_errmsg(database))
        sqlite3_close_v2(database)
      } else if let errorText = sqlite3_errstr(result) {
        message = String(cString: errorText)
      } else {
        message = "SQLite could not open the database."
      }
      throw SQLiteAgentEventJournalError.database(code: result, message: message)
    }

    handle = database
    let extendedResult = sqlite3_extended_result_codes(database, 1)
    guard extendedResult == SQLITE_OK else {
      let error = error(for: extendedResult)
      sqlite3_close_v2(database)
      handle = nil
      throw error
    }
    let timeoutResult = sqlite3_busy_timeout(database, Int32(busyTimeoutMilliseconds))
    guard timeoutResult == SQLITE_OK else {
      let error = error(for: timeoutResult)
      sqlite3_close_v2(database)
      handle = nil
      throw error
    }
  }

  deinit {
    if let handle {
      sqlite3_close_v2(handle)
    }
  }

  func close() throws {
    guard let handle else {
      return
    }
    let result = sqlite3_close(handle)
    guard result == SQLITE_OK else {
      throw error(for: result)
    }
    self.handle = nil
  }

  func execute(_ sql: String) throws {
    var errorMessage: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(try rawHandle(), sql, nil, nil, &errorMessage)
    guard result == SQLITE_OK else {
      let message: String
      if let errorMessage {
        message = String(cString: errorMessage)
      } else if let handle {
        message = String(cString: sqlite3_errmsg(handle))
      } else {
        message = "SQLite execution failed after the connection closed."
      }
      sqlite3_free(errorMessage)
      throw SQLiteAgentEventJournalError.database(code: result, message: message)
    }
  }

  func prepare(_ sql: String) throws -> SQLiteStatement {
    try SQLiteStatement(connection: self, sql: sql)
  }

  func scalarInt64(_ sql: String) throws -> Int64 {
    let statement = try prepare(sql)
    guard try statement.step() == .row else {
      throw SQLiteAgentEventJournalError.corruptSchema(
        "A required SQLite scalar query returned no row."
      )
    }
    return try statement.columnInt64(at: 0)
  }

  func scalarText(_ sql: String, maximumBytes: Int) throws -> String {
    let statement = try prepare(sql)
    guard try statement.step() == .row else {
      throw SQLiteAgentEventJournalError.corruptSchema(
        "A required SQLite scalar query returned no row."
      )
    }
    return try statement.columnText(at: 0, maximumBytes: maximumBytes)
  }

  func changes() throws -> Int {
    Int(sqlite3_changes(try rawHandle()))
  }

  func withImmediateTransaction<Value>(_ body: () throws -> Value) throws -> Value {
    try execute("BEGIN IMMEDIATE")
    do {
      let value = try body()
      try execute("COMMIT")
      return value
    } catch {
      do {
        try execute("ROLLBACK")
      } catch let rollbackError {
        invalidate()
        throw rollbackError
      }
      throw error
    }
  }

  func rawHandle() throws -> OpaquePointer {
    guard let handle else {
      throw SQLiteAgentEventJournalError.closed
    }
    return handle
  }

  func error(for result: Int32) -> SQLiteAgentEventJournalError {
    let message: String
    if let handle {
      message = String(cString: sqlite3_errmsg(handle))
    } else if let errorText = sqlite3_errstr(result) {
      message = String(cString: errorText)
    } else {
      message = "Unknown SQLite failure."
    }
    return .database(code: result, message: message)
  }

  private func invalidate() {
    if let handle {
      sqlite3_close_v2(handle)
      self.handle = nil
    }
  }
}
