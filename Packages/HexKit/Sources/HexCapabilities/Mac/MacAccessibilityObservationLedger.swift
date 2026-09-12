import Dispatch
import Foundation
import HexCore

/// Binds a bounded, single-use observation to the run that obtained it. This is not an approval.
public actor MacAccessibilityObservationLedger {
  private let now: @Sendable () -> UInt64
  private let lifetimeNanoseconds: UInt64
  private let maximumEntries: Int
  private var entries: [String: MacAccessibilityObservationLedgerEntry] = [:]

  public init(
    lifetimeNanoseconds: UInt64 = 60_000_000_000, maximumEntries: Int = 64,
    now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
  ) {
    self.lifetimeNanoseconds = min(lifetimeNanoseconds, 60_000_000_000)
    self.maximumEntries = min(max(1, maximumEntries), 64)
    self.now = now
  }

  public func record(_ snapshot: MacAccessibilitySnapshot, runID: AgentRunID) throws {
    try Task.checkCancellation()
    purgeExpired()
    guard UUID(uuidString: snapshot.observationID) != nil, snapshot.processIdentifier > 0,
      !snapshot.bundleIdentifier.isEmpty, snapshot.elements.count <= 512,
      Set(snapshot.elements.map(\.path)).count == snapshot.elements.count,
      entries[snapshot.observationID] == nil
    else { throw MacToolError.accessibilityObservationFailed }
    entries = entries.filter {
      $0.value.runID != runID || $0.value.snapshot.bundleIdentifier != snapshot.bundleIdentifier
    }
    guard entries.count < maximumEntries else { throw MacToolError.authorizationStateUnavailable }
    let current = now()
    let (expiry, overflow) = current.addingReportingOverflow(lifetimeNanoseconds)
    entries[snapshot.observationID] = MacAccessibilityObservationLedgerEntry(
      runID: runID, snapshot: snapshot, capturedAt: current,
      expiresAt: overflow ? UInt64.max : expiry)
  }

  public func validate(
    observationID: String, bundleIdentifier: String, selector: MacAccessibilitySelector,
    runID: AgentRunID
  ) throws -> MacAccessibilityElementSnapshot {
    try Task.checkCancellation()
    purgeExpired()
    guard let entry = entries[observationID], entry.runID == runID,
      entry.snapshot.bundleIdentifier == bundleIdentifier
    else { throw MacToolError.accessibilityObservationStale }
    let matches = entry.snapshot.elements.filter { element in
      (selector.path == nil || selector.path == element.path)
        && (selector.identifier == nil || selector.identifier == element.identifier)
        && (selector.role == nil || selector.role == element.role)
        && (selector.title == nil || selector.title == element.title)
    }
    if let occurrence = selector.occurrence {
      guard matches.indices.contains(occurrence) else {
        throw MacToolError.accessibilityElementNotFound
      }
      return matches[occurrence]
    }
    guard let match = matches.first else { throw MacToolError.accessibilityElementNotFound }
    guard matches.count == 1 else { throw MacToolError.accessibilityElementAmbiguous }
    return match
  }

  public func take(
    observationID: String, bundleIdentifier: String, selector: MacAccessibilitySelector,
    runID: AgentRunID
  ) throws -> MacAccessibilityElementSnapshot {
    let element = try validate(
      observationID: observationID, bundleIdentifier: bundleIdentifier, selector: selector,
      runID: runID)
    entries[observationID] = nil
    return element
  }

  private func purgeExpired() {
    let current = now()
    entries = entries.filter { $0.value.capturedAt <= current && $0.value.expiresAt > current }
  }

}
