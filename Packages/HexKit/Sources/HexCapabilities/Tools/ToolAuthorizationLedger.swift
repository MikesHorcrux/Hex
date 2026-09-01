import Dispatch
import HexCore

/// Carries the exact validated call shown to the authorization provider into execution.
/// It is not a grant store: the runtime still owns the allow or deny decision.
actor ToolAuthorizationLedger {
  private struct Key: Hashable, Sendable {
    let runID: AgentRunID
    let toolCallID: ToolCallID
  }

  private struct Entry: Sendable {
    let call: ToolCall
    let expiresAt: UInt64
  }

  private let maximumEntries: Int
  private let lifetimeNanoseconds: UInt64
  private var entries: [Key: Entry] = [:]

  init(
    maximumEntries: Int = 512,
    lifetimeNanoseconds: UInt64 = 60 * 1_000_000_000
  ) {
    self.maximumEntries = maximumEntries
    self.lifetimeNanoseconds = lifetimeNanoseconds
  }

  func record(call: ToolCall, runID: AgentRunID) throws {
    let now = DispatchTime.now().uptimeNanoseconds
    purgeExpired(at: now)
    let key = Key(runID: runID, toolCallID: call.id)
    if let existing = entries[key] {
      guard existing.call == call else {
        throw ToolAuthorizationLedgerError.conflictingRequest
      }
      return
    }
    guard entries.count < maximumEntries else {
      throw ToolAuthorizationLedgerError.capacityExceeded
    }
    let (candidate, overflowed) = now.addingReportingOverflow(lifetimeNanoseconds)
    entries[key] = Entry(call: call, expiresAt: overflowed ? UInt64.max : candidate)
  }

  func take(call: ToolCall, runID: AgentRunID) throws {
    let now = DispatchTime.now().uptimeNanoseconds
    purgeExpired(at: now)
    let key = Key(runID: runID, toolCallID: call.id)
    guard let entry = entries.removeValue(forKey: key) else {
      throw ToolAuthorizationLedgerError.authorizationRequired
    }
    guard entry.call == call else {
      throw ToolAuthorizationLedgerError.conflictingRequest
    }
  }

  func remove(callID: ToolCallID, runID: AgentRunID) {
    purgeExpired(at: DispatchTime.now().uptimeNanoseconds)
    entries.removeValue(forKey: Key(runID: runID, toolCallID: callID))
  }

  private func purgeExpired(at now: UInt64) {
    let expired = entries.compactMap { key, entry in
      entry.expiresAt <= now ? key : nil
    }
    for key in expired {
      entries.removeValue(forKey: key)
    }
  }
}
