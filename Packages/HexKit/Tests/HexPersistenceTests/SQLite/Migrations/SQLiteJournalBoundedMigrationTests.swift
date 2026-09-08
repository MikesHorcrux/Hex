import Foundation
import Testing

@testable import HexPersistence

@Suite("SQLite journal bounded migrations")
struct SQLiteJournalBoundedMigrationTests {
  @Test
  func versionOneMigrationRejectsRecordCountOverConfiguredBoundBeforeMutation() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let databaseURL = JournalTestSupport.databaseURL(in: directory)
    _ = try JournalTestSupport.createVersionOneFixture(at: databaseURL)

    do {
      let journal = try await SQLiteAgentEventJournal.open(
        configuration: SQLiteAgentEventJournalConfiguration(
          databaseURL: databaseURL,
          maximumRecoveryRecordCount: 1
        )
      )
      try await journal.close()
      Issue.record("Migration copied more records than the configured integrity bound.")
    } catch let error as SQLiteAgentEventJournalError {
      guard case .integrityRecordLimitExceeded(let maximum) = error else {
        Issue.record("Expected integrityRecordLimitExceeded, received \(error).")
        return
      }
      #expect(maximum == 1)
    }

    #expect(try JournalTestSupport.userVersion(at: databaseURL) == 1)
    #expect(try JournalTestSupport.tableExists("journal_checkpoints", at: databaseURL) == false)
  }

  @Test
  func versionOneMigrationRejectsDecodedBytesOverConfiguredBoundBeforeMutation() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let databaseURL = JournalTestSupport.databaseURL(in: directory)
    _ = try JournalTestSupport.createVersionOneFixture(at: databaseURL)

    do {
      let journal = try await SQLiteAgentEventJournal.open(
        configuration: SQLiteAgentEventJournalConfiguration(
          databaseURL: databaseURL,
          maximumRecoveryBytes: 36
        )
      )
      try await journal.close()
      Issue.record("Migration copied more decoded bytes than the configured integrity bound.")
    } catch let error as SQLiteAgentEventJournalError {
      guard case .integrityByteLimitExceeded(_, let maximum) = error else {
        Issue.record("Expected integrityByteLimitExceeded, received \(error).")
        return
      }
      #expect(maximum == 36)
    }

    #expect(try JournalTestSupport.userVersion(at: databaseURL) == 1)
    #expect(try JournalTestSupport.tableExists("journal_checkpoints", at: databaseURL) == false)
  }
}
