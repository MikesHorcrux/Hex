import HexCore

/// Actor-owned append validation for a run created after whole-journal admission.
/// Recovered runs are terminal before admission returns and do not need a retained state.
struct SQLiteJournalActiveRunState {
  private let runID: AgentRunID
  private let terminalReservationBytes: Int
  private var nextSequence: UInt64 = 1
  private var lifecycle: SQLiteRunLifecycleValidator
  private(set) var usage: SQLiteJournalIntegrityUsage = .zero

  init(
    runID: AgentRunID,
    configuration: SQLiteAgentEventJournalConfiguration
  ) throws {
    self.runID = runID
    lifecycle = SQLiteRunLifecycleValidator(runID: runID)
    terminalReservationBytes = try SQLiteInterruptedRunTerminal.encodedRecordByteCount(
      runIDTextByteCount: runID.description.utf8.count,
      configuration: configuration
    )
  }

  func appending(
    _ record: AgentEventRecord,
    recordByteCount: Int,
    configuration: SQLiteAgentEventJournalConfiguration
  ) throws -> Self {
    guard record.runID == runID, record.sequence == nextSequence else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "The run's durable sequence no longer matches its owned append state."
      )
    }
    let isFirstRecord = nextSequence == 1
    guard record.event.startsRun == isFirstRecord else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "A run must contain exactly one leading runStarted record."
      )
    }

    var updated = self
    try updated.lifecycle.consume(record.event, sequence: record.sequence)
    if case .runCompleted = record.event {
      try updated.lifecycle.validateSuccessfulCompletion()
    }
    let previousReservation =
      isFirstRecord
      ? SQLiteJournalIntegrityUsage.zero
      : SQLiteJournalIntegrityUsage(
        runCount: 0,
        recordCount: 1,
        byteCount: terminalReservationBytes
      )
    let retainsReservation = !record.event.terminatesRun
    // The decoder has already bounded all record fields and the reservation is likewise bounded.
    let appendedUsage = SQLiteJournalIntegrityUsage(
      runCount: isFirstRecord ? 1 : 0,
      recordCount: retainsReservation ? 2 : 1,
      byteCount: recordByteCount
        + (isFirstRecord ? runID.description.utf8.count : 0)
        + (retainsReservation ? terminalReservationBytes : 0)
    )
    updated.usage = try usage.replacing(
      previousReservation,
      with: appendedUsage,
      configuration: configuration
    )
    // SQLite sequences are bounded by Int64.max, so their successor fits UInt64.
    updated.nextSequence = record.sequence + 1
    return updated
  }
}
