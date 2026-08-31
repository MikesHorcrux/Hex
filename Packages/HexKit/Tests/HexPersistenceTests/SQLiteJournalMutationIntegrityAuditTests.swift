import Foundation
import HexCore
import Testing

@testable import HexPersistence

@Suite("Persistence audit mutation integrity probes")
struct SQLiteJournalMutationIntegrityAuditTests {
  @Test
  func recoveryObservesCancellationDuringTerminalization() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let databaseURL = JournalTestSupport.databaseURL(in: directory)
    let runID = AgentRunID()
    let initial = try await SQLiteAgentEventJournal.open(
      configuration: SQLiteAgentEventJournalConfiguration(databaseURL: databaseURL)
    )
    _ = try await initial.append(.runStarted, to: runID)
    try await initial.close()

    let recoveryTask = Task {
      let recovering = try await SQLiteAgentEventJournal.open(
        configuration: SQLiteAgentEventJournalConfiguration(
          databaseURL: databaseURL,
          clock: {
            withUnsafeCurrentTask { task in
              task?.cancel()
            }
            return Date(timeIntervalSince1970: 1_700_000_000)
          }
        )
      )
      try await recovering.close()
    }
    do {
      try await recoveryTask.value
      Issue.record("Recovery returned successfully after cancellation during terminalization.")
    } catch is CancellationError {
      // Expected.
    }

    #expect(
      try JournalTestSupport.scalarInt64(
        "SELECT COUNT(*) FROM event_records WHERE run_id = '\(runID)'",
        at: databaseURL
      ) == 1
    )
  }

  @Test
  func recoveryRejectsCorruptUnrelatedRunBeforeTerminalization() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let databaseURL = JournalTestSupport.databaseURL(in: directory)
    let corruptedRunID = AgentRunID()
    let interruptedRunID = AgentRunID()
    let initial = try await SQLiteAgentEventJournal.open(
      configuration: SQLiteAgentEventJournalConfiguration(databaseURL: databaseURL)
    )
    _ = try await initial.append(.runStarted, to: corruptedRunID)
    _ = try await initial.append(.runCompleted, to: corruptedRunID)
    _ = try await initial.append(.runStarted, to: interruptedRunID)
    try await initial.close()
    try JournalTestSupport.execute(
      "UPDATE event_records SET payload = X'FF' WHERE run_id = '\(corruptedRunID)' AND sequence = 1",
      at: databaseURL
    )

    do {
      _ = try await SQLiteAgentEventJournal.open(
        configuration: SQLiteAgentEventJournalConfiguration(databaseURL: databaseURL)
      )
      Issue.record("Recovery ignored corrupt durable state outside the interrupted run.")
    } catch is SQLiteAgentEventJournalError {
      // Expected.
    }
    #expect(
      try JournalTestSupport.scalarInt64(
        "SELECT COUNT(*) FROM event_records WHERE run_id = '\(interruptedRunID)'",
        at: databaseURL
      ) == 1
    )
  }

  @Test
  func appendRejectsDuplicateLogicalRunIDWithDifferentUUIDCase() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = JournalTestSupport.configuration(in: directory)
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    guard let rawRunID = UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE") else {
      Issue.record("Static UUID fixture was invalid.")
      return
    }
    let runID = AgentRunID(rawValue: rawRunID)
    _ = try await journal.append(.runStarted, to: runID)
    _ = try await journal.append(.runCompleted, to: runID)
    let lowercaseRunID = runID.description.lowercased()
    try JournalTestSupport.withConnection(at: configuration.databaseURL) { connection in
      try connection.execute("PRAGMA ignore_check_constraints = ON")
      try connection.execute(
        "UPDATE event_records SET run_id = '\(lowercaseRunID)' WHERE run_id = '\(runID)'"
      )
      try connection.execute(
        "UPDATE runs SET run_id = '\(lowercaseRunID)' WHERE run_id = '\(runID)'"
      )
    }

    do {
      _ = try await journal.append(.runStarted, to: runID)
      Issue.record("Append admitted a second row for the same logical run UUID.")
    } catch is SQLiteAgentEventJournalError {
      // Expected fail-closed behavior.
    }
    #expect(
      try JournalTestSupport.scalarInt64(
        "SELECT COUNT(*) FROM runs WHERE lower(run_id) = lower('\(runID)')",
        at: configuration.databaseURL
      ) == 1
    )
    try await journal.close()
  }

  @Test
  func readRejectsNoncanonicalEventIDAfterConstraintBypass() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = JournalTestSupport.configuration(in: directory)
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let runID = AgentRunID()
    _ = try await journal.append(.runStarted, to: runID)
    _ = try await journal.append(.runCompleted, to: runID)
    let secondEventID = try JournalTestSupport.withConnection(at: configuration.databaseURL) {
      connection in
      try connection.scalarText(
        "SELECT event_id FROM event_records WHERE run_id = '\(runID)' AND sequence = 2",
        maximumBytes: 64
      )
    }
    try JournalTestSupport.withConnection(at: configuration.databaseURL) { connection in
      try connection.execute("PRAGMA ignore_check_constraints = ON")
      try connection.execute(
        "UPDATE event_records SET event_id = '\(secondEventID.lowercased())' WHERE run_id = '\(runID)' AND sequence = 2"
      )
    }

    do {
      _ = try await journal.records(for: runID, after: nil, limit: 10)
      Issue.record("Returned a record whose event_id was not canonical UUID text.")
    } catch is SQLiteAgentEventJournalError {
      // Expected fail-closed behavior.
    }
    try await journal.close()
  }

  @Test
  func eventIDUniquenessRejectsCaseVariantCollision() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = JournalTestSupport.configuration(in: directory)
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let runID = AgentRunID()
    _ = try await journal.append(.runStarted, to: runID)
    _ = try await journal.append(.runCompleted, to: runID)
    let firstEventID = try JournalTestSupport.withConnection(at: configuration.databaseURL) {
      connection in
      try connection.scalarText(
        "SELECT event_id FROM event_records WHERE run_id = '\(runID)' AND sequence = 1",
        maximumBytes: 64
      )
    }

    do {
      try JournalTestSupport.withConnection(at: configuration.databaseURL) { connection in
        try connection.execute("PRAGMA ignore_check_constraints = ON")
        try connection.execute(
          "UPDATE event_records SET event_id = '\(firstEventID.lowercased())' WHERE run_id = '\(runID)' AND sequence = 2"
        )
      }
      Issue.record("Expected NOCASE event_id uniqueness to reject the logical collision.")
    } catch is SQLiteAgentEventJournalError {
      // Expected.
    }
    try await journal.close()
  }

  @Test
  func canonicalUUIDConstraintRejectsAdditionalHyphen() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = JournalTestSupport.configuration(in: directory)
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let runID = AgentRunID()
    _ = try await journal.append(.runStarted, to: runID)

    do {
      try JournalTestSupport.execute(
        "UPDATE event_records SET event_id = '-2345678-1234-1234-1234-123456789ABC'",
        at: configuration.databaseURL
      )
      Issue.record("The canonical UUID constraint admitted an additional hyphen.")
    } catch is SQLiteAgentEventJournalError {
      // Expected.
    }
    #expect(
      try JournalTestSupport.scalarInt64(
        "SELECT COUNT(*) FROM event_records WHERE event_id LIKE '-%'",
        at: configuration.databaseURL
      ) == 0
    )
    try await journal.close()
  }

  @Test
  func replacingDatabaseAndLockPathsDoesNotAdmitSecondOwner() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = JournalTestSupport.configuration(in: directory)
    let first = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let runID = AgentRunID()
    _ = try await first.append(.runStarted, to: runID)

    for suffix in ["-shm", "-wal", ".lock", ""] {
      let path = configuration.databaseURL.path + suffix
      if FileManager.default.fileExists(atPath: path) {
        try FileManager.default.removeItem(atPath: path)
      }
    }

    do {
      let second = try await SQLiteAgentEventJournal.open(configuration: configuration)
      try await second.close()
      Issue.record("Replacing both owned paths admitted a second live journal owner.")
    } catch let error as SQLiteAgentEventJournalError {
      guard case .ownershipUnavailable = error else {
        Issue.record("Expected ownershipUnavailable, received \(error).")
        return
      }
    }
    try await first.close()
  }

  @Test
  func directoryOwnershipLockBlocksHelperProcess() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let journal = try await SQLiteAgentEventJournal.open(
      configuration: JournalTestSupport.configuration(in: directory)
    )
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [
      "-c",
      """
      import fcntl, os, sys
      descriptor = os.open(sys.argv[1], os.O_RDONLY)
      try:
          fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
      except BlockingIOError:
          sys.exit(0)
      sys.exit(1)
      """,
      directory.path,
    ]
    try process.run()
    process.waitUntilExit()

    #expect(process.terminationReason == .exit)
    #expect(process.terminationStatus == 0)
    try await journal.close()
  }

  @Test
  func replacingDedicatedDirectoryDefinesANewOwnershipBoundary() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    let movedDirectory = directory.deletingLastPathComponent().appendingPathComponent(
      "\(directory.lastPathComponent)-moved",
      isDirectory: true
    )
    defer {
      JournalTestSupport.removeTemporaryDirectory(directory)
      JournalTestSupport.removeTemporaryDirectory(movedDirectory)
    }
    let configuration = JournalTestSupport.configuration(in: directory)
    let first = try await SQLiteAgentEventJournal.open(configuration: configuration)
    try FileManager.default.moveItem(at: directory, to: movedDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)

    do {
      _ = try await first.records(for: .init(), after: nil, limit: 1)
      Issue.record("Expected the original owner to reject replacement of its directory path.")
    } catch let error as SQLiteAgentEventJournalError {
      guard case .invalidConfiguration = error else {
        Issue.record("Expected invalidConfiguration, received \(error).")
        return
      }
    }

    let second = try await SQLiteAgentEventJournal.open(configuration: configuration)
    try await second.close()
    try await first.close()
  }

  @Test
  func appendRejectsCorruptExistingPayloadBeforeMutation() async throws {
    let fixture = try await makeOpenRun()
    defer { JournalTestSupport.removeTemporaryDirectory(fixture.directory) }
    try JournalTestSupport.execute(
      "UPDATE event_records SET payload = X'FF' WHERE run_id = '\(fixture.runID)' AND sequence = 1",
      at: fixture.configuration.databaseURL
    )

    do {
      _ = try await fixture.journal.append(
        .messageAppended(Message(role: .user, content: [.text("must-not-commit")])),
        to: fixture.runID
      )
      Issue.record("Append committed on top of a corrupt durable run.")
    } catch is SQLiteAgentEventJournalError {
      // Expected fail-closed behavior.
    }
    #expect(
      try JournalTestSupport.scalarInt64(
        "SELECT COUNT(*) FROM event_records WHERE run_id = '\(fixture.runID)'",
        at: fixture.configuration.databaseURL
      ) == 1
    )
    try await fixture.journal.close()
  }

  @Test
  func checkpointRejectsCorruptReferencedEventBeforeMutation() async throws {
    let fixture = try await makeOpenRun()
    defer { JournalTestSupport.removeTemporaryDirectory(fixture.directory) }
    try JournalTestSupport.execute(
      "UPDATE event_records SET payload = X'FF' WHERE run_id = '\(fixture.runID)' AND sequence = 1",
      at: fixture.configuration.databaseURL
    )

    do {
      _ = try await fixture.journal.writeCheckpoint(
        for: fixture.runID,
        through: 1,
        snapshot: .object(["state": .string("must-not-commit")])
      )
      Issue.record("Checkpoint committed against a corrupt durable event.")
    } catch is SQLiteAgentEventJournalError {
      // Expected fail-closed behavior.
    }
    #expect(
      try JournalTestSupport.scalarInt64(
        "SELECT COUNT(*) FROM journal_checkpoints WHERE run_id = '\(fixture.runID)'",
        at: fixture.configuration.databaseURL
      ) == 0
    )
    try await fixture.journal.close()
  }

  @Test
  func latestCheckpointRejectsCorruptReferencedEvent() async throws {
    let fixture = try await makeOpenRun()
    defer { JournalTestSupport.removeTemporaryDirectory(fixture.directory) }
    let checkpoint = try await fixture.journal.writeCheckpoint(
      for: fixture.runID,
      through: 1,
      snapshot: .object(["state": .string("unsafe-if-log-corrupt")])
    )
    try JournalTestSupport.execute(
      "UPDATE event_records SET payload = X'FF' WHERE run_id = '\(fixture.runID)' AND sequence = 1",
      at: fixture.configuration.databaseURL
    )

    do {
      let returned = try await fixture.journal.latestCheckpoint(for: fixture.runID)
      Issue.record(
        "Returned checkpoint \(String(describing: returned)) despite corrupt event; fixture \(checkpoint)."
      )
    } catch is SQLiteAgentEventJournalError {
      // Expected fail-closed behavior.
    }
    try await fixture.journal.close()
  }

  @Test
  func appendRejectsCorruptUnrelatedCheckpointBeforeMutation() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = JournalTestSupport.configuration(in: directory)
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let corruptedRunID = AgentRunID()
    _ = try await journal.append(.runStarted, to: corruptedRunID)
    _ = try await journal.append(.runCompleted, to: corruptedRunID)
    _ = try await journal.writeCheckpoint(for: corruptedRunID, through: 2, snapshot: .null)
    let targetRunID = AgentRunID()
    _ = try await journal.append(.runStarted, to: targetRunID)
    try JournalTestSupport.execute(
      "UPDATE journal_checkpoints SET snapshot = X'FF' WHERE run_id = '\(corruptedRunID)'",
      at: configuration.databaseURL
    )

    do {
      _ = try await journal.append(
        .messageAppended(Message(role: .user, content: [.text("must-not-commit")])),
        to: targetRunID
      )
      Issue.record("Append ignored a corrupt checkpoint elsewhere in the journal.")
    } catch is SQLiteAgentEventJournalError {
      // Expected.
    }
    #expect(
      try JournalTestSupport.scalarInt64(
        "SELECT COUNT(*) FROM event_records WHERE run_id = '\(targetRunID)'",
        at: configuration.databaseURL
      ) == 1
    )
    try await journal.close()
  }

  @Test
  func checkpointRejectsCorruptUnrelatedEventBeforeMutation() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = JournalTestSupport.configuration(in: directory)
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let corruptedRunID = AgentRunID()
    _ = try await journal.append(.runStarted, to: corruptedRunID)
    _ = try await journal.append(.runCompleted, to: corruptedRunID)
    let targetRunID = AgentRunID()
    _ = try await journal.append(.runStarted, to: targetRunID)
    try JournalTestSupport.execute(
      "UPDATE event_records SET payload = X'FF' WHERE run_id = '\(corruptedRunID)' AND sequence = 1",
      at: configuration.databaseURL
    )

    do {
      _ = try await journal.writeCheckpoint(for: targetRunID, through: 1, snapshot: .null)
      Issue.record("Checkpoint insertion ignored a corrupt unrelated event.")
    } catch is SQLiteAgentEventJournalError {
      // Expected.
    }
    #expect(
      try JournalTestSupport.scalarInt64(
        "SELECT COUNT(*) FROM journal_checkpoints WHERE run_id = '\(targetRunID)'",
        at: configuration.databaseURL
      ) == 0
    )
    try await journal.close()
  }

  @Test
  func latestCheckpointRejectsCorruptUnrelatedEvent() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let configuration = JournalTestSupport.configuration(in: directory)
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let targetRunID = AgentRunID()
    _ = try await journal.append(.runStarted, to: targetRunID)
    _ = try await journal.writeCheckpoint(for: targetRunID, through: 1, snapshot: .null)
    let corruptedRunID = AgentRunID()
    _ = try await journal.append(.runStarted, to: corruptedRunID)
    _ = try await journal.append(.runCompleted, to: corruptedRunID)
    try JournalTestSupport.execute(
      "UPDATE event_records SET payload = X'FF' WHERE run_id = '\(corruptedRunID)' AND sequence = 1",
      at: configuration.databaseURL
    )

    do {
      _ = try await journal.latestCheckpoint(for: targetRunID)
      Issue.record("latestCheckpoint ignored a corrupt unrelated event.")
    } catch is SQLiteAgentEventJournalError {
      // Expected.
    }
    try await journal.close()
  }

  @Test
  func wholeJournalValidationEnforcesRecordAndByteBounds() async throws {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    defer { JournalTestSupport.removeTemporaryDirectory(directory) }
    let databaseURL = JournalTestSupport.databaseURL(in: directory)
    let initial = try await SQLiteAgentEventJournal.open(
      configuration: SQLiteAgentEventJournalConfiguration(databaseURL: databaseURL)
    )
    let runID = AgentRunID()
    _ = try await initial.append(.runStarted, to: runID)
    _ = try await initial.append(
      .messageAppended(Message(role: .user, content: [.text("integrity-bound-fixture")])),
      to: runID
    )
    _ = try await initial.append(.runCompleted, to: runID)
    try await initial.close()
    let decodedBytes = try JournalTestSupport.scalarInt64(
      """
      SELECT length(run_id) + (
        SELECT SUM(
          length(event_id) + length(run_id) + length(kind) +
          COALESCE(length(tool_call_id), 0) + length(payload)
        )
        FROM event_records WHERE run_id = runs.run_id
      )
      FROM runs WHERE run_id = '\(runID)'
      """,
      at: databaseURL
    )

    let recordBounded = try await SQLiteAgentEventJournal.open(
      configuration: SQLiteAgentEventJournalConfiguration(
        databaseURL: databaseURL,
        maximumRecoveryRecordCount: 2
      )
    )
    do {
      _ = try await recordBounded.latestCheckpoint(for: runID)
      Issue.record("Expected the whole-journal record bound to fail closed.")
    } catch let error as SQLiteAgentEventJournalError {
      #expect(error == .integrityRecordLimitExceeded(maximum: 2))
    }
    try await recordBounded.close()

    let byteBounded = try await SQLiteAgentEventJournal.open(
      configuration: SQLiteAgentEventJournalConfiguration(
        databaseURL: databaseURL,
        maximumRecoveryBytes: Int(decodedBytes) - 1
      )
    )
    do {
      _ = try await byteBounded.latestCheckpoint(for: runID)
      Issue.record("Expected the whole-journal byte bound to fail closed.")
    } catch let error as SQLiteAgentEventJournalError {
      guard case .integrityByteLimitExceeded(_, let maximum) = error else {
        Issue.record("Expected integrityByteLimitExceeded, received \(error).")
        return
      }
      #expect(maximum == Int(decodedBytes) - 1)
    }
    try await byteBounded.close()
  }

  private func makeOpenRun() async throws -> (
    directory: URL,
    configuration: SQLiteAgentEventJournalConfiguration,
    journal: SQLiteAgentEventJournal,
    runID: AgentRunID
  ) {
    let directory = try JournalTestSupport.makeTemporaryDirectory()
    let configuration = JournalTestSupport.configuration(in: directory)
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let runID = AgentRunID()
    _ = try await journal.append(.runStarted, to: runID)
    return (directory, configuration, journal, runID)
  }
}
