import Dispatch
import HexCore

/// Actor-owned, bounded pending authorization state for process identities. The external
/// authorization provider still decides whether a request is allowed; this ledger only carries the
/// exact file snapshot from the displayed authorization request to the subsequent execution.
public actor ProcessAuthorizationLedger {
  private struct Key: Hashable, Sendable {
    let runID: AgentRunID
    let toolCallID: ToolCallID
  }

  struct Snapshot: Sendable {
    let request: ProcessExecutionRequest
    let identity: ProcessExecutionIdentity
    let storageBytes: Int
    let expiresAt: UInt64
  }

  private static let maximumEntries = 4_096
  private static let maximumBytes = 8 * 1_024 * 1_024
  private static let snapshotLifetimeNanoseconds: UInt64 = 60 * 1_000_000_000

  private var pending: [Key: Snapshot] = [:]
  private var pendingBytes = 0

  public init() {}

  /// Records an authorization snapshot. Repeated identical requests for the same call are
  /// idempotent; a conflicting request cannot replace the invocation that was displayed. Unrelated
  /// pending requests are bounded by both count and approximate retained UTF-8 bytes. A monotonic
  /// one-minute deadline bounds denied or abandoned requests when the host has no denial callback.
  func record(
    runID: AgentRunID,
    toolCallID: ToolCallID,
    request: ProcessExecutionRequest,
    identity: ProcessExecutionIdentity
  ) throws {
    let now = DispatchTime.now().uptimeNanoseconds
    purgeExpired(at: now)
    let key = Key(runID: runID, toolCallID: toolCallID)
    if let existing = pending[key] {
      guard existing.request == request, existing.identity == identity else {
        throw ProcessExecutionError.authorizationStateUnavailable
      }
      return
    }

    guard
      let storageBytes = Self.storageByteCount(request: request, identity: identity),
      storageBytes <= Self.maximumBytes
    else {
      throw ProcessExecutionError.authorizationStateUnavailable
    }
    guard pending.count < Self.maximumEntries else {
      throw ProcessExecutionError.authorizationStateUnavailable
    }
    guard pendingBytes <= Self.maximumBytes - storageBytes else {
      throw ProcessExecutionError.authorizationStateUnavailable
    }

    let (candidateExpiration, overflowed) = now.addingReportingOverflow(
      Self.snapshotLifetimeNanoseconds
    )
    let expiration = overflowed ? UInt64.max : candidateExpiration
    pending[key] = Snapshot(
      request: request,
      identity: identity,
      storageBytes: storageBytes,
      expiresAt: expiration
    )
    pendingBytes += storageBytes
  }

  /// Removes and returns the identity displayed for this exact call. A missing snapshot is a
  /// fail-closed authorization failure; execution must not silently create a new approval.
  func take(
    runID: AgentRunID,
    toolCallID: ToolCallID
  ) -> Snapshot? {
    purgeExpired(at: DispatchTime.now().uptimeNanoseconds)
    return remove(Key(runID: runID, toolCallID: toolCallID))
  }

  /// Discards one pending request. Tool control uses this on cancellation and validation failure
  /// so a malformed retry cannot leave an old approval waiting for accidental reuse.
  func remove(runID: AgentRunID, toolCallID: ToolCallID) {
    purgeExpired(at: DispatchTime.now().uptimeNanoseconds)
    _ = remove(Key(runID: runID, toolCallID: toolCallID))
  }

  /// Allows a host to discard pending requests when a run ends or an authorization is denied.
  public func remove(runID: AgentRunID) {
    purgeExpired(at: DispatchTime.now().uptimeNanoseconds)
    let keys = pending.keys.filter { $0.runID == runID }
    for key in keys {
      _ = remove(key)
    }
  }

  /// Purges expired denied or abandoned requests. Record, take, and remove also perform this
  /// lazily; a host may call this method from its ordinary capability-maintenance cadence.
  public func purgeExpired() {
    purgeExpired(at: DispatchTime.now().uptimeNanoseconds)
  }

  private func purgeExpired(at now: UInt64) {
    let expiredKeys = pending.compactMap { key, snapshot in
      snapshot.expiresAt <= now ? key : nil
    }
    for key in expiredKeys {
      _ = remove(key)
    }
  }

  @discardableResult
  private func remove(_ key: Key) -> Snapshot? {
    guard let snapshot = pending.removeValue(forKey: key) else {
      return nil
    }
    pendingBytes -= snapshot.storageBytes
    return snapshot
  }

  private static func storageByteCount(
    request: ProcessExecutionRequest,
    identity: ProcessExecutionIdentity
  ) -> Int? {
    // Include a fixed allowance for collection/hash-table bookkeeping and scalar metadata in
    // addition to every retained string. This is a conservative memory admission budget, not a
    // wire-format size claim.
    var total = 1_024

    func add(_ bytes: Int) -> Bool {
      guard bytes >= 0 else {
        return false
      }
      let (candidate, overflowed) = total.addingReportingOverflow(bytes)
      guard !overflowed else {
        return false
      }
      total = candidate
      return true
    }

    guard
      add(request.executable.path.utf8.count),
      add(request.workingDirectory.path.utf8.count),
      add(request.arguments.count * MemoryLayout<String>.stride),
      add(request.environment.count * MemoryLayout<(String, String)>.stride)
    else {
      return nil
    }
    for argument in request.arguments {
      guard add(argument.utf8.count) else {
        return nil
      }
    }
    if let expectedIdentity = request.expectedIdentity {
      for value in expectedIdentity.canonicalValues {
        guard add(value.utf8.count) else {
          return nil
        }
      }
    }
    guard
      let environmentBytes = ProcessExecutionEnvironment.byteCount(request.environment),
      add(environmentBytes)
    else {
      return nil
    }
    for value in identity.canonicalValues {
      guard add(value.utf8.count) else {
        return nil
      }
    }
    return total
  }
}
