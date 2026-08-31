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
  }

  private let maximumEntries = 4_096
  private var pending: [Key: Snapshot] = [:]

  public init() {}

  /// Records an authorization snapshot. Repeated identical requests for the same call are
  /// idempotent; a conflicting request cannot replace the invocation that was displayed. Unrelated
  /// pending requests are bounded so denied calls cannot grow memory forever.
  func record(
    runID: AgentRunID,
    toolCallID: ToolCallID,
    request: ProcessExecutionRequest,
    identity: ProcessExecutionIdentity
  ) throws {
    let key = Key(runID: runID, toolCallID: toolCallID)
    if let existing = pending[key] {
      guard existing.request == request, existing.identity == identity else {
        throw ProcessExecutionError.authorizationStateUnavailable
      }
      return
    }
    guard pending.count < maximumEntries else {
      throw ProcessExecutionError.authorizationStateUnavailable
    }
    pending[key] = Snapshot(request: request, identity: identity)
  }

  /// Removes and returns the identity displayed for this exact call. A missing snapshot is a
  /// fail-closed authorization failure; execution must not silently create a new approval.
  func take(
    runID: AgentRunID,
    toolCallID: ToolCallID
  ) -> Snapshot? {
    pending.removeValue(forKey: Key(runID: runID, toolCallID: toolCallID))
  }

  /// Allows a host to discard pending requests when a run ends or an authorization is denied.
  public func remove(runID: AgentRunID) {
    pending = pending.filter { $0.key.runID != runID }
  }
}
