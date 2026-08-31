import Foundation
import HexCore

/// A single-owner, SQLite-backed durable event journal.
public actor SQLiteAgentEventJournal: AgentEventJournal {
  let configuration: SQLiteAgentEventJournalConfiguration
  let databaseURL: URL
  var connection: SQLiteConnection?
  var fileLock: SQLiteJournalFileLock?

  /// Runs repaired during this specific open. A later idempotent open reports an empty array.
  public private(set) var recoveredRuns: [InterruptedAgentRun] = []

  private init(configuration: SQLiteAgentEventJournalConfiguration) {
    self.configuration = configuration
    databaseURL = configuration.databaseURL.standardizedFileURL.resolvingSymlinksInPath()
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
  }

  func requireConnection() throws -> SQLiteConnection {
    guard let connection else {
      throw SQLiteAgentEventJournalError.closed
    }
    return connection
  }

  private func initialize() throws {
    try Task.checkCancellation()

    let parentURL = databaseURL.deletingLastPathComponent()
    let fileManager = FileManager()
    var isDirectory = ObjCBool(false)
    if fileManager.fileExists(atPath: parentURL.path, isDirectory: &isDirectory) {
      guard isDirectory.boolValue else {
        throw SQLiteAgentEventJournalError.invalidConfiguration(
          "The database parent path is not a directory."
        )
      }
    } else {
      try fileManager.createDirectory(
        at: parentURL,
        withIntermediateDirectories: true,
        attributes: nil
      )
    }

    var databaseIsDirectory = ObjCBool(false)
    if fileManager.fileExists(atPath: databaseURL.path, isDirectory: &databaseIsDirectory),
      databaseIsDirectory.boolValue
    {
      throw SQLiteAgentEventJournalError.invalidConfiguration(
        "The database URL refers to a directory."
      )
    }

    fileLock = try SQLiteJournalFileLock(databaseURL: databaseURL)
    do {
      let openedConnection = try SQLiteConnection(
        databaseURL: databaseURL,
        busyTimeoutMilliseconds: configuration.busyTimeoutMilliseconds
      )
      connection = openedConnection
      try SQLiteJournalMigrator.prepare(
        connection: openedConnection,
        busyTimeoutMilliseconds: configuration.busyTimeoutMilliseconds,
        maximumTextBytes: configuration.maximumTextBytes
      )
      recoveredRuns = try recoverInterruptedRuns()
    } catch {
      connection = nil
      fileLock = nil
      throw error
    }
  }
}
