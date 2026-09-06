extension SQLiteAgentEventJournal {
  func withImmediateOwnedTransaction<Value>(
    connection: SQLiteConnection,
    _ body: () throws -> Value
  ) throws -> Value {
    try withOwnedTransaction(connection: connection) { beforeCommit, afterCommit in
      try connection.withImmediateTransaction(
        beforeCommit: beforeCommit,
        afterCommit: afterCommit,
        body
      )
    }
  }

  func withDeferredOwnedTransaction<Value>(
    connection: SQLiteConnection,
    _ body: () throws -> Value
  ) throws -> Value {
    try withOwnedTransaction(connection: connection) { beforeCommit, afterCommit in
      try connection.withDeferredTransaction(
        beforeCommit: beforeCommit,
        afterCommit: afterCommit,
        body
      )
    }
  }

  private func withOwnedTransaction<Value>(
    connection: SQLiteConnection,
    _ transaction: (
      _ beforeCommit: () throws -> Void,
      _ afterCommit: () throws -> Void
    ) throws -> Value
  ) throws -> Value {
    do {
      return try transaction(
        { try validateOwnershipBoundary() },
        { try validateOwnershipBoundary() }
      )
    } catch let error as SQLiteAgentEventJournalError {
      if error == .commitOutcomeUncertain {
        invalidateAfterUncertainCommit(connection: connection)
      }
      throw error
    }
  }

  private func validateOwnershipBoundary() throws {
    guard let secureDirectory, let fileLock else {
      throw SQLiteAgentEventJournalError.closed
    }
    try secureDirectory.hardenSQLiteFiles()
    try fileLock.validateIdentities(in: secureDirectory)
  }

  private func invalidateAfterUncertainCommit(connection: SQLiteConnection) {
    connection.invalidate()
    self.connection = nil
    fileLock = nil
    secureDirectory = nil
    integrityUsage = nil
    integrityDataVersion = nil
    activeRunStates.removeAll()
  }
}
