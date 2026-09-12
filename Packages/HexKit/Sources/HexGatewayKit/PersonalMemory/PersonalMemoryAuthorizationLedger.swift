import Dispatch
import Foundation
import HexCapabilities
import HexCore
import HexPersonality

/// Carries the exact validated call displayed in the authorization request into execution.
/// Authorization is still decided by the runtime's injected provider; this ledger only prevents
/// an unapproved or conflicting call from reaching the durable store.
actor PersonalMemoryAuthorizationLedger {
  private let maximumEntries: Int = 512
  private let lifetimeNanoseconds: UInt64 = 60 * 1_000_000_000
  private var calls:
    [PersonalMemoryAuthorizationLedgerKey: PersonalMemoryAuthorizationLedgerEntry] = [:]

  func record(call: ToolCall, runID: AgentRunID) throws {
    let now = DispatchTime.now().uptimeNanoseconds
    purgeExpired(at: now)
    let key = PersonalMemoryAuthorizationLedgerKey(runID: runID, toolCallID: call.id)
    if let existing = calls[key] {
      guard existing.call == call else {
        throw PersonalMemoryToolError.authorizationStateUnavailable
      }
      return
    }
    guard calls.count < maximumEntries else {
      throw PersonalMemoryToolError.authorizationStateUnavailable
    }
    let (expiry, overflowed) = now.addingReportingOverflow(lifetimeNanoseconds)
    calls[key] = PersonalMemoryAuthorizationLedgerEntry(
      call: call, expiresAt: overflowed ? UInt64.max : expiry)
  }

  func take(call: ToolCall, runID: AgentRunID) throws {
    purgeExpired(at: DispatchTime.now().uptimeNanoseconds)
    let key = PersonalMemoryAuthorizationLedgerKey(runID: runID, toolCallID: call.id)
    guard let entry = calls.removeValue(forKey: key) else {
      throw PersonalMemoryToolError.authorizationRequired
    }
    guard entry.call == call else {
      throw PersonalMemoryToolError.authorizationStateUnavailable
    }
  }

  func remove(callID: ToolCallID, runID: AgentRunID) {
    purgeExpired(at: DispatchTime.now().uptimeNanoseconds)
    calls.removeValue(
      forKey: PersonalMemoryAuthorizationLedgerKey(runID: runID, toolCallID: callID))
  }

  private func purgeExpired(at now: UInt64) {
    let expired = calls.compactMap { key, entry in
      entry.expiresAt <= now ? key : nil
    }
    for key in expired {
      calls.removeValue(forKey: key)
    }
  }
}
