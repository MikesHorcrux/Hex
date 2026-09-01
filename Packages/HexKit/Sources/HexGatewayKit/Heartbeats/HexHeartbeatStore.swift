import Foundation

/// Durable scheduler state and atomic occurrence claims. A store must make `claim` and `complete`
/// single-owner transactions: a process restart may observe a persisted lease, but it must never
/// silently replace that lease with a new one for the same occurrence.
public protocol HexHeartbeatStore: Sendable {
  func load() async throws -> HexHeartbeatStoreSnapshot

  /// Atomically replaces the complete snapshot. Implementations must use a crash-safe replacement
  /// boundary (or an equivalent transactional mechanism) before returning.
  func replace(_ snapshot: HexHeartbeatStoreSnapshot) async throws

  /// Applies a read/modify/write mutation while holding the store's cross-process transaction
  /// boundary. Callers must use this for schedule mutations so two resident processes cannot
  /// overwrite one another's changes after independently loading the same snapshot.
  func mutate(
    _ mutation: @Sendable (HexHeartbeatStoreSnapshot) throws -> HexHeartbeatStoreSnapshot
  ) async throws -> HexHeartbeatStoreSnapshot

  /// Persists a lease only when the exact occurrence is still due and unclaimed.
  func claim(
    _ lease: HexHeartbeatLease,
    at now: Date
  ) async throws -> HexHeartbeatClaimDisposition

  /// Commits an outcome and advances the schedule only for the exact active lease. `at` is the
  /// authoritative completion time and must be supplied by the owning clock. Repeating the same
  /// non-expired completion is idempotent; a different lease is rejected as stale.
  func complete(
    _ completion: HexHeartbeatCompletion,
    at now: Date
  ) async throws -> HexHeartbeatCompletionDisposition

  /// Converts expired, unknown-in-process leases to a durable interruption. The occurrence is
  /// advanced past the current time so a restart cannot launch the same occurrence twice.
  func reconcileExpiredLeases(at now: Date) async throws -> HexHeartbeatStoreSnapshot
}
