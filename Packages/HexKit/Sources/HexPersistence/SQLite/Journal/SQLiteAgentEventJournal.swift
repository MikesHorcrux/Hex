import Foundation
import HexCore

/// A single-owner, SQLite-backed durable event journal.
public actor SQLiteAgentEventJournal: AgentEventJournal {
  let configuration: SQLiteAgentEventJournalConfiguration
  let databaseURL: URL
  var connection: SQLiteConnection?
  var fileLock: SQLiteJournalFileLock?
  var secureDirectory: SQLiteJournalSecureDirectory?
  // Whole-journal admission establishes these baselines. Only successful owned commits
  // update usage; another SQLite connection's commit invalidates the data version.
  var integrityUsage: SQLiteJournalIntegrityUsage?
  var integrityDataVersion: Int64?
  var activeRunStates: [AgentRunID: SQLiteJournalActiveRunState] = [:]

  /// Runs repaired during this specific open. A later idempotent open reports an empty array.
  public private(set) var recoveredRuns: [InterruptedAgentRun] = []

  private init(configuration: SQLiteAgentEventJournalConfiguration) {
    self.configuration = configuration
    databaseURL = configuration.databaseURL.standardizedFileURL
  }

  /// Acquires ownership, configures SQLite, migrates, validates, and recovers before returning.
  public static func open(
    configuration: SQLiteAgentEventJournalConfiguration
  ) async throws -> SQLiteAgentEventJournal {
    let validated = try configuration.validated()
    let journal = SQLiteAgentEventJournal(configuration: validated)
    try await journal.initialize()
    return journal
  }

  /// Closes SQLite and releases exclusive file ownership. Further operations fail with `closed`.
  public func close() throws {
    if let connection {
      try connection.close()
      self.connection = nil
    }
    fileLock = nil
    secureDirectory = nil
    integrityUsage = nil
    integrityDataVersion = nil
    activeRunStates.removeAll()
  }

  func requireConnection() throws -> SQLiteConnection {
    guard let connection else {
      throw SQLiteAgentEventJournalError.closed
    }
    guard let secureDirectory, let fileLock else {
      throw SQLiteAgentEventJournalError.closed
    }
    try secureDirectory.hardenSQLiteFiles()
    try fileLock.validateIdentities(in: secureDirectory)
    return connection
  }

  private func initialize() throws {
    try Task.checkCancellation()

    let secureDirectory = try SQLiteJournalSecureDirectory(databaseURL: databaseURL)
    self.secureDirectory = secureDirectory
    let fileLock = try SQLiteJournalFileLock(secureDirectory: secureDirectory)
    self.fileLock = fileLock
    do {
      try secureDirectory.hardenSQLiteFiles()
      try fileLock.validateIdentities(in: secureDirectory)
      let openedConnection = try SQLiteConnection(
        databaseURL: secureDirectory.sqliteDatabaseURL,
        busyTimeoutMilliseconds: configuration.busyTimeoutMilliseconds
      )
      connection = openedConnection
      try SQLiteJournalMigrator.prepare(
        connection: openedConnection,
        configuration: configuration,
        beforeCommit: {
          try secureDirectory.hardenSQLiteFiles()
          try fileLock.validateIdentities(in: secureDirectory)
        },
        afterCommit: {
          try secureDirectory.hardenSQLiteFiles()
          try fileLock.validateIdentities(in: secureDirectory)
        },
        validateMigratedData: {
          try self.validateWholeJournalIntegrity(connection: openedConnection)
        }
      )
      try secureDirectory.hardenSQLiteFiles()
      try fileLock.validateIdentities(in: secureDirectory)
      recoveredRuns = try recoverInterruptedRuns()
      try secureDirectory.hardenSQLiteFiles()
      try fileLock.validateIdentities(in: secureDirectory)
    } catch {
      connection = nil
      self.fileLock = nil
      self.secureDirectory = nil
      integrityUsage = nil
      integrityDataVersion = nil
      activeRunStates.removeAll()
      throw error
    }
  }
}
