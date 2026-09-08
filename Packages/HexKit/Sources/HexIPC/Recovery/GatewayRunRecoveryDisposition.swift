public enum GatewayRunRecoveryDisposition: Codable, Equatable, Sendable {
  /// minimumReplaySequence is the lowest accepted exclusive live cursor, not the first record.
  case resident(
    snapshot: GatewayRunSnapshot, minimumReplaySequence: UInt64, journal: GatewayJournalRunSnapshot?
  )
  /// Durable history has no reconstructed or newly manufactured live invocation.
  case journaled(GatewayJournalRunSnapshot)
  case unknown
}
