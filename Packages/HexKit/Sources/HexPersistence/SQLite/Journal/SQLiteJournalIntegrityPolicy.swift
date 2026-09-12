import Foundation

/// Eager validation retains the original bounded-archive contract for diagnostic callers.
/// Incremental validation has no lifetime size/count quota; it validates writes and requested
/// pages and restores only transactionally checkpointed active runs.
public enum SQLiteJournalIntegrityPolicy: String, Sendable {
  case boundedArchive, incremental
}
