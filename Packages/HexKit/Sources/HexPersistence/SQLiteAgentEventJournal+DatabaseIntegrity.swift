extension SQLiteAgentEventJournal {
  func validatePhysicalDatabaseIntegrity(
    connection: SQLiteConnection,
    checksCancellation: Bool
  ) throws {
    if checksCancellation {
      try Task.checkCancellation()
    }
    let pageSize = try connection.scalarInt64("PRAGMA page_size")
    let pageCount = try connection.scalarInt64("PRAGMA page_count")
    guard pageSize > 0, pageCount >= 0 else {
      throw SQLiteAgentEventJournalError.corruptSchema(
        "SQLite reported an invalid physical page size or page count."
      )
    }
    let (databaseBytes, overflowed) = pageSize.multipliedReportingOverflow(by: pageCount)
    guard
      !overflowed,
      databaseBytes <= Int64(configuration.maximumDatabaseBytes)
    else {
      throw SQLiteAgentEventJournalError.databaseSizeLimitExceeded(
        actual: overflowed ? Int.max : Int(databaseBytes),
        maximum: configuration.maximumDatabaseBytes
      )
    }

    if checksCancellation {
      try Task.checkCancellation()
    }
    let statement = try connection.prepare("PRAGMA integrity_check(1)")
    guard try statement.step() == .row else {
      throw SQLiteAgentEventJournalError.corruptSchema(
        "SQLite integrity verification returned no result."
      )
    }
    let result = try statement.columnText(
      at: 0,
      maximumBytes: configuration.maximumTextBytes
    )
    guard result == "ok" else {
      throw SQLiteAgentEventJournalError.corruptSchema(
        "SQLite physical integrity verification failed."
      )
    }
    guard try statement.step() == .done else {
      throw SQLiteAgentEventJournalError.corruptSchema(
        "SQLite integrity verification returned unexpected extra output."
      )
    }
    if checksCancellation {
      try Task.checkCancellation()
    }
  }
}
