import Foundation

@testable import HexPersistence

actor SQLiteWriteBlocker {
  private let connection: SQLiteConnection

  init(databaseURL: URL) throws {
    connection = try JournalTestSupport.makeConnection(
      at: databaseURL,
      busyTimeoutMilliseconds: 5_000
    )
  }

  func begin() throws {
    try connection.execute("BEGIN IMMEDIATE")
  }

  func release() throws {
    try connection.execute("ROLLBACK")
  }
}
