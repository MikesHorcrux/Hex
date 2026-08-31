import Foundation
import SQLite3

final class SQLiteStatement {
  private let connection: SQLiteConnection
  private var handle: OpaquePointer?

  init(connection: SQLiteConnection, sql: String) throws {
    self.connection = connection
    var statement: OpaquePointer?
    let result = sqlite3_prepare_v2(try connection.rawHandle(), sql, -1, &statement, nil)
    guard result == SQLITE_OK, let statement else {
      throw connection.error(for: result)
    }
    self.handle = statement
  }

  deinit {
    if let handle {
      sqlite3_finalize(handle)
    }
  }

  func bind(_ value: Int64, at index: Int32) throws {
    try check(sqlite3_bind_int64(try rawHandle(), index, value))
  }

  func bind(_ value: String, at index: Int32) throws {
    let byteCount = value.utf8.count
    guard byteCount <= Int(Int32.max) else {
      throw SQLiteAgentEventJournalError.database(
        code: SQLITE_TOOBIG,
        message: "A bound SQLite string exceeded Int32.max bytes."
      )
    }
    let statement = try rawHandle()
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    let result = value.withCString { characters in
      sqlite3_bind_text(statement, index, characters, Int32(byteCount), transient)
    }
    try check(result)
  }

  func bind(_ value: Data, at index: Int32) throws {
    guard value.count <= Int(Int32.max) else {
      throw SQLiteAgentEventJournalError.database(
        code: SQLITE_TOOBIG,
        message: "A bound SQLite blob exceeded Int32.max bytes."
      )
    }
    if value.isEmpty {
      try check(sqlite3_bind_zeroblob(try rawHandle(), index, 0))
      return
    }
    let statement = try rawHandle()
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    let result = value.withUnsafeBytes { bytes in
      sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transient)
    }
    try check(result)
  }

  func bindNull(at index: Int32) throws {
    try check(sqlite3_bind_null(try rawHandle(), index))
  }

  func step() throws -> SQLiteStepResult {
    let result = sqlite3_step(try rawHandle())
    switch result {
    case SQLITE_ROW:
      return .row
    case SQLITE_DONE:
      return .done
    default:
      throw connection.error(for: result)
    }
  }

  func columnInt64(at index: Int32) throws -> Int64 {
    let statement = try rawHandle()
    guard sqlite3_column_type(statement, index) == SQLITE_INTEGER else {
      throw typeMismatch(at: index, expected: "INTEGER")
    }
    return sqlite3_column_int64(statement, index)
  }

  func columnOptionalInt64(at index: Int32) throws -> Int64? {
    let statement = try rawHandle()
    if sqlite3_column_type(statement, index) == SQLITE_NULL {
      return nil
    }
    return try columnInt64(at: index)
  }

  func columnText(at index: Int32, maximumBytes: Int) throws -> String {
    let statement = try rawHandle()
    guard sqlite3_column_type(statement, index) == SQLITE_TEXT else {
      throw typeMismatch(at: index, expected: "TEXT")
    }
    let count = Int(sqlite3_column_bytes(statement, index))
    guard count <= maximumBytes else {
      throw SQLiteAgentEventJournalError.textTooLarge(
        actual: count,
        maximum: maximumBytes
      )
    }
    guard let text = sqlite3_column_text(statement, index) else {
      throw typeMismatch(at: index, expected: "non-null TEXT")
    }
    let data = Data(bytes: text, count: count)
    guard let value = String(data: data, encoding: .utf8) else {
      throw typeMismatch(at: index, expected: "valid UTF-8 TEXT")
    }
    return value
  }

  func columnOptionalText(at index: Int32, maximumBytes: Int) throws -> String? {
    let statement = try rawHandle()
    if sqlite3_column_type(statement, index) == SQLITE_NULL {
      return nil
    }
    return try columnText(at: index, maximumBytes: maximumBytes)
  }

  func columnBlob(at index: Int32, maximumBytes: Int) throws -> Data {
    let statement = try rawHandle()
    guard sqlite3_column_type(statement, index) == SQLITE_BLOB else {
      throw typeMismatch(at: index, expected: "BLOB")
    }
    let count = Int(sqlite3_column_bytes(statement, index))
    guard count <= maximumBytes else {
      throw SQLiteAgentEventJournalError.payloadTooLarge(
        actual: count,
        maximum: maximumBytes
      )
    }
    guard count > 0 else {
      return Data()
    }
    guard let bytes = sqlite3_column_blob(statement, index) else {
      throw typeMismatch(at: index, expected: "non-null BLOB")
    }
    return Data(bytes: bytes, count: count)
  }

  private func rawHandle() throws -> OpaquePointer {
    guard let handle else {
      throw SQLiteAgentEventJournalError.closed
    }
    return handle
  }

  private func check(_ result: Int32) throws {
    guard result == SQLITE_OK else {
      throw connection.error(for: result)
    }
  }

  private func typeMismatch(at index: Int32, expected: String) -> SQLiteAgentEventJournalError {
    SQLiteAgentEventJournalError.corruptRecord(
      "SQLite column \(index) was not \(expected)."
    )
  }
}
