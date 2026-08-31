import Darwin
import Foundation
import HexCore
import Testing

@testable import HexPersistence

@Suite("SQLite journal file security")
struct SQLiteJournalFileSecurityTests {
  @Test
  func hardensPrivateDirectoryAndFilesContainingPersonalData() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    guard chmod(directory.path, 0o755) == 0 else {
      Issue.record("Could not prepare a permissive directory fixture.")
      return
    }
    let configuration = JournalTestSupport.configuration(in: directory)
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let runID = AgentRunID()
    _ = try await journal.append(.runStarted, to: runID)
    _ = try await journal.append(
      .messageAppended(
        Message(role: .user, content: [.text("private-personal-journal-content")])
      ),
      to: runID
    )

    try expectModeAndOwner(at: directory, type: S_IFDIR, permissions: 0o700)
    let databaseURL = configuration.databaseURL
    for fileURL in [
      databaseURL,
      URL(fileURLWithPath: databaseURL.path + ".lock"),
      URL(fileURLWithPath: databaseURL.path + "-wal"),
      URL(fileURLWithPath: databaseURL.path + "-shm"),
    ] {
      try expectModeAndOwner(at: fileURL, type: S_IFREG, permissions: 0o600)
    }
    try await journal.close()

    guard
      chmod(directory.path, 0o755) == 0,
      chmod(databaseURL.path, 0o644) == 0,
      chmod(databaseURL.path + ".lock", 0o644) == 0
    else {
      Issue.record("Could not prepare permissive reopen fixtures.")
      return
    }
    let reopened = try await SQLiteAgentEventJournal.open(configuration: configuration)
    try expectModeAndOwner(at: directory, type: S_IFDIR, permissions: 0o700)
    try expectModeAndOwner(at: databaseURL, type: S_IFREG, permissions: 0o600)
    try expectModeAndOwner(
      at: URL(fileURLWithPath: databaseURL.path + ".lock"),
      type: S_IFREG,
      permissions: 0o600
    )
    try await reopened.close()
  }

  private func expectModeAndOwner(
    at url: URL,
    type: mode_t,
    permissions: mode_t
  ) throws {
    let fileStatus = try JournalTestSupport.fileStatus(at: url)
    #expect(fileStatus.st_mode & S_IFMT == type)
    #expect(fileStatus.st_mode & 0o777 == permissions)
    #expect(fileStatus.st_uid == geteuid())
    if type == S_IFREG {
      #expect(fileStatus.st_nlink == 1)
    }
  }
}
