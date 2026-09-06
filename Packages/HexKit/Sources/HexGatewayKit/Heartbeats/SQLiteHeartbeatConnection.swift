import Foundation
import SQLite3

/// Synchronous connection exclusively owned by SQLiteHexHeartbeatStore's actor. Bindings and
/// returned rows are bounded values; no SQLite pointer crosses a task or actor boundary.
final class SQLiteHeartbeatConnection {
  enum Value {
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
    case null
  }

  private var handle: OpaquePointer?

  init(path: String) throws {
    var opened: OpaquePointer?
    let result = sqlite3_open_v2(
      path, &opened,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil
    )
    guard result == SQLITE_OK, let opened else {
      if let opened { sqlite3_close_v2(opened) }
      throw SQLiteHexHeartbeatStoreError.unavailable
    }
    handle = opened
    guard sqlite3_busy_timeout(opened, 5_000) == SQLITE_OK else {
      sqlite3_close_v2(opened)
      handle = nil
      throw SQLiteHexHeartbeatStoreError.unavailable
    }
  }

  deinit { if let handle { sqlite3_close_v2(handle) } }

  func close() throws {
    guard let handle else { return }
    guard sqlite3_close(handle) == SQLITE_OK else { throw SQLiteHexHeartbeatStoreError.unavailable }
    self.handle = nil
  }

  func execute(_ sql: String, _ bindings: [Value] = []) throws {
    _ = try rows(sql, bindings, maximumRows: 0)
  }

  func rows(
    _ sql: String, _ bindings: [Value] = [], maximumRows: Int = 1,
    maximumCellBytes: Int = 131_072
  ) throws -> [[Value]] {
    guard let handle else { throw SQLiteHexHeartbeatStoreError.unavailable }
    var prepared: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else {
      throw SQLiteHexHeartbeatStoreError.corrupt
    }
    defer { sqlite3_finalize(prepared) }
    // SQLITE_TRANSIENT is SQLite's documented copy-before-return sentinel, not retained Swift memory.
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (offset, value) in bindings.enumerated() {
      let index = Int32(offset + 1)
      let result: Int32
      switch value {
      case .integer(let number): result = sqlite3_bind_int64(prepared, index, number)
      case .real(let number): result = sqlite3_bind_double(prepared, index, number)
      case .null: result = sqlite3_bind_null(prepared, index)
      case .text(let text):
        guard text.utf8.count <= maximumCellBytes else {
          throw SQLiteHexHeartbeatStoreError.payloadTooLarge
        }
        result = text.withCString {
          sqlite3_bind_text(prepared, index, $0, Int32(text.utf8.count), transient)
        }
      case .blob(let data):
        guard data.count <= maximumCellBytes else {
          throw SQLiteHexHeartbeatStoreError.payloadTooLarge
        }
        result = data.withUnsafeBytes {
          sqlite3_bind_blob(prepared, index, $0.baseAddress, Int32(data.count), transient)
        }
      }
      guard result == SQLITE_OK else { throw SQLiteHexHeartbeatStoreError.unavailable }
    }
    var output: [[Value]] = []
    while true {
      let result = sqlite3_step(prepared)
      if result == SQLITE_DONE { return output }
      guard result == SQLITE_ROW else { throw SQLiteHexHeartbeatStoreError.unavailable }
      guard output.count < maximumRows else { throw SQLiteHexHeartbeatStoreError.corrupt }
      var row: [Value] = []
      for index in 0..<sqlite3_column_count(prepared) {
        switch sqlite3_column_type(prepared, index) {
        case SQLITE_NULL: row.append(.null)
        case SQLITE_INTEGER: row.append(.integer(sqlite3_column_int64(prepared, index)))
        case SQLITE_FLOAT: row.append(.real(sqlite3_column_double(prepared, index)))
        case SQLITE_TEXT, SQLITE_BLOB:
          let count = Int(sqlite3_column_bytes(prepared, index))
          guard count <= maximumCellBytes else {
            throw SQLiteHexHeartbeatStoreError.payloadTooLarge
          }
          let data: Data
          if count == 0 {
            data = Data()
          } else {
            guard let bytes = sqlite3_column_blob(prepared, index) else {
              throw SQLiteHexHeartbeatStoreError.corrupt
            }
            data = Data(bytes: bytes, count: count)
          }
          if sqlite3_column_type(prepared, index) == SQLITE_TEXT {
            guard let text = String(data: data, encoding: .utf8) else {
              throw SQLiteHexHeartbeatStoreError.corrupt
            }
            row.append(.text(text))
          } else {
            row.append(.blob(data))
          }
        default: throw SQLiteHexHeartbeatStoreError.corrupt
        }
      }
      output.append(row)
    }
  }

  func transaction<T>(_ body: () throws -> T) throws -> T {
    try execute("BEGIN IMMEDIATE")
    let value: T
    do { value = try body() } catch {
      try? execute("ROLLBACK")
      throw error
    }
    do { try execute("COMMIT") } catch {
      try? close()
      throw SQLiteHexHeartbeatStoreError.commitOutcomeUncertain
    }
    return value
  }
}
