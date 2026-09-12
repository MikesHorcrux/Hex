struct SQLiteJournalIntegrityUsage: Codable, Equatable, Sendable {
  static let zero = SQLiteJournalIntegrityUsage(
    runCount: 0,
    recordCount: 0,
    byteCount: 0
  )

  let runCount: Int
  let recordCount: Int
  let byteCount: Int

  func replacing(
    _ previous: SQLiteJournalIntegrityUsage,
    with replacement: SQLiteJournalIntegrityUsage,
    configuration: SQLiteAgentEventJournalConfiguration
  ) throws -> SQLiteJournalIntegrityUsage {
    let runCount = try replacingCount(
      self.runCount,
      previous: previous.runCount,
      replacement: replacement.runCount
    )
    let recordCount = try replacingCount(
      self.recordCount,
      previous: previous.recordCount,
      replacement: replacement.recordCount
    )
    let byteCount = try replacingCount(
      self.byteCount,
      previous: previous.byteCount,
      replacement: replacement.byteCount
    )

    guard runCount <= configuration.auditRunLimit else {
      throw SQLiteAgentEventJournalError.integrityRunLimitExceeded(
        maximum: configuration.auditRunLimit
      )
    }
    guard recordCount <= configuration.auditRecordLimit else {
      throw SQLiteAgentEventJournalError.integrityRecordLimitExceeded(
        maximum: configuration.auditRecordLimit
      )
    }
    guard byteCount <= configuration.auditByteLimit else {
      throw SQLiteAgentEventJournalError.integrityByteLimitExceeded(
        actual: byteCount,
        maximum: configuration.auditByteLimit
      )
    }

    return SQLiteJournalIntegrityUsage(
      runCount: runCount,
      recordCount: recordCount,
      byteCount: byteCount
    )
  }

  private func replacingCount(
    _ current: Int,
    previous: Int,
    replacement: Int
  ) throws -> Int {
    let (withoutPrevious, subtractionOverflowed) = current.subtractingReportingOverflow(previous)
    guard !subtractionOverflowed, withoutPrevious >= 0 else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "The journal integrity accounting no longer matches its durable target run."
      )
    }
    let (updated, additionOverflowed) = withoutPrevious.addingReportingOverflow(replacement)
    guard !additionOverflowed, updated >= 0 else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "The journal integrity accounting overflowed while replacing a target run."
      )
    }
    return updated
  }
}
