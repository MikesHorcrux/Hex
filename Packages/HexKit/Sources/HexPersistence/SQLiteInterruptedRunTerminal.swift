import HexCore

enum SQLiteInterruptedRunTerminal {
  static var event: AgentEvent {
    .runFailed(
      AgentFailure(
        code: .invalidState,
        message: "Run interrupted before reaching a terminal state.",
        isRetryable: false
      )
    )
  }

  static func encodedRecordByteCount(
    runIDTextByteCount: Int,
    configuration: SQLiteAgentEventJournalConfiguration
  ) throws -> Int {
    let payload = try AgentEventCodec.encode(event: event)
    guard payload.count <= configuration.maximumPayloadBytes else {
      throw SQLiteAgentEventJournalError.payloadTooLarge(
        actual: payload.count,
        maximum: configuration.maximumPayloadBytes
      )
    }
    let kindByteCount = event.journalKind.utf8.count
    guard
      runIDTextByteCount <= configuration.maximumTextBytes,
      kindByteCount <= configuration.maximumTextBytes
    else {
      throw SQLiteAgentEventJournalError.textTooLarge(
        actual: max(runIDTextByteCount, kindByteCount),
        maximum: configuration.maximumTextBytes
      )
    }

    // Current-schema event and run identifiers are canonical UUID strings and therefore 36 bytes.
    var byteCount = 36
    for additionalBytes in [runIDTextByteCount, kindByteCount, payload.count] {
      let (nextByteCount, overflowed) = byteCount.addingReportingOverflow(additionalBytes)
      guard !overflowed else {
        throw SQLiteAgentEventJournalError.integrityByteLimitExceeded(
          actual: Int.max,
          maximum: configuration.maximumRecoveryBytes
        )
      }
      byteCount = nextByteCount
    }
    return byteCount
  }
}
