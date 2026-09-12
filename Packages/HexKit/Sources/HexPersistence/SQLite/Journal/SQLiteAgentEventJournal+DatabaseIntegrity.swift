extension SQLiteAgentEventJournal {
  func validatePhysicalDatabaseIntegrity(
    connection: SQLiteConnection,
    checksCancellation: Bool
  ) throws {
    if checksCancellation {
      try Task.checkCancellation()
    }
    try validatePhysicalDatabaseSize(connection: connection)

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

  func validatePhysicalDatabaseSize(
    connection: SQLiteConnection
  ) throws {
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
      configuration.integrityPolicy == .incremental
        || databaseBytes <= Int64(configuration.maximumDatabaseBytes)
    else {
      throw SQLiteAgentEventJournalError.databaseSizeLimitExceeded(
        actual: overflowed ? Int.max : Int(databaseBytes),
        maximum: configuration.maximumDatabaseBytes
      )
    }
  }

  func currentDataVersion(
    connection: SQLiteConnection
  ) throws -> Int64 {
    let version = try connection.scalarInt64("PRAGMA data_version")
    guard version >= 0 else {
      throw SQLiteAgentEventJournalError.corruptSchema(
        "SQLite reported an invalid data version."
      )
    }
    return version
  }

  func validateIntegrityDataVersion(
    connection: SQLiteConnection
  ) throws {
    guard let integrityDataVersion else {
      throw SQLiteAgentEventJournalError.closed
    }
    guard try currentDataVersion(connection: connection) == integrityDataVersion else {
      // An unexpected writer invalidates the cached baseline. Diagnose its data once so
      // callers retain the precise corruption error, but never adopt that writer's state.
      if configuration.integrityPolicy == .boundedArchive {
        try validateWholeJournalIntegrity(connection: connection)
      }
      throw SQLiteAgentEventJournalError.corruptRecord(
        "The journal changed through another SQLite connection while it was open."
      )
    }
  }
}
