import Darwin
import Foundation
import Testing

@testable import HexPersistence

@Suite("SQLite journal path security")
struct SQLiteJournalPathSecurityTests {
  @Test
  func rejectsSymbolicLinkParent() async throws {
    let base = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(base) }
    let realDirectory = base.appendingPathComponent("real", isDirectory: true)
    let linkedDirectory = base.appendingPathComponent("linked", isDirectory: true)
    try FileManager().createDirectory(at: realDirectory, withIntermediateDirectories: false)
    try FileManager().createSymbolicLink(at: linkedDirectory, withDestinationURL: realDirectory)

    await expectInvalidPath(
      linkedDirectory.appendingPathComponent("journal.sqlite", isDirectory: false)
    )
  }

  @Test
  func rejectsSymbolicLinkDatabase() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let target = directory.appendingPathComponent("target.sqlite", isDirectory: false)
    let databaseURL = JournalTestSupport.databaseURL(in: directory)
    #expect(FileManager().createFile(atPath: target.path, contents: Data()))
    try FileManager().createSymbolicLink(at: databaseURL, withDestinationURL: target)

    await expectInvalidPath(databaseURL)
  }

  @Test
  func rejectsSpecialDatabaseFile() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let databaseURL = JournalTestSupport.databaseURL(in: directory)
    guard mkfifo(databaseURL.path, 0o600) == 0 else {
      Issue.record("Could not create the FIFO fixture.")
      return
    }

    await expectInvalidPath(databaseURL)
  }

  @Test
  func rejectsHardLinkedDatabaseAliases() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = JournalTestSupport.configuration(in: directory)
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let aliasURL = directory.appendingPathComponent("journal-alias.sqlite", isDirectory: false)
    guard link(configuration.databaseURL.path, aliasURL.path) == 0 else {
      Issue.record("Could not create the hard-link fixture.")
      return
    }

    await expectInvalidPath(aliasURL)
    do {
      _ = try await journal.records(for: .init(), after: nil, limit: 1)
      Issue.record("Expected the active owner to detect the new hard-link alias.")
    } catch let error as SQLiteAgentEventJournalError {
      guard case .invalidConfiguration = error else {
        Issue.record("Expected invalidConfiguration, received \(error).")
        return
      }
    }
    try await journal.close()
  }

  @Test
  func rejectsSymbolicLinkSQLiteSidecar() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = JournalTestSupport.configuration(in: directory)
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    try await journal.close()
    let target = directory.appendingPathComponent("sidecar-target", isDirectory: false)
    let sidecarPath = configuration.databaseURL.path + "-wal"
    if FileManager().fileExists(atPath: sidecarPath) {
      try FileManager().removeItem(atPath: sidecarPath)
    }
    #expect(FileManager().createFile(atPath: target.path, contents: Data()))
    try FileManager().createSymbolicLink(
      atPath: sidecarPath,
      withDestinationPath: target.path
    )

    await expectInvalidPath(configuration.databaseURL)
  }

  @Test
  func replacingHeldLockPathDoesNotAdmitAnotherOwner() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = JournalTestSupport.configuration(in: directory)
    let first = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let lockURL = URL(fileURLWithPath: configuration.databaseURL.path + ".lock")
    try FileManager().removeItem(at: lockURL)
    #expect(FileManager().createFile(atPath: lockURL.path, contents: Data()))

    do {
      let second = try await SQLiteAgentEventJournal.open(configuration: configuration)
      try await second.close()
      Issue.record("Expected the database-bound owner lock to reject a second live owner.")
    } catch let error as SQLiteAgentEventJournalError {
      guard case .ownershipUnavailable = error else {
        Issue.record("Expected ownershipUnavailable, received \(error).")
        return
      }
    }

    do {
      _ = try await first.records(for: .init(), after: nil, limit: 1)
      Issue.record("Expected the first owner to detect replacement of its held lock path.")
    } catch let error as SQLiteAgentEventJournalError {
      guard case .invalidConfiguration = error else {
        Issue.record("Expected invalidConfiguration, received \(error).")
        return
      }
    }
    try await first.close()
  }

  private func expectInvalidPath(_ databaseURL: URL) async {
    do {
      _ = try await SQLiteAgentEventJournal.open(
        configuration: SQLiteAgentEventJournalConfiguration(databaseURL: databaseURL)
      )
      Issue.record("Expected the unsafe journal path to fail closed.")
    } catch let error as SQLiteAgentEventJournalError {
      guard case .invalidConfiguration = error else {
        Issue.record("Expected invalidConfiguration, received \(error).")
        return
      }
    } catch {
      Issue.record("Expected a journal error, received \(error).")
    }
  }
}
