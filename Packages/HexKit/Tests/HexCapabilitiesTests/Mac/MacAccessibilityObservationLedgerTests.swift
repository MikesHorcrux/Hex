import Foundation
import HexCapabilities
import HexCore
import Testing
import os

@Suite("Run-bound native observations")
struct MacAccessibilityObservationLedgerTests {
  @Test
  func observationCannotCrossRunOrApplicationAndIsSingleUse() async throws {
    let ledger = MacAccessibilityObservationLedger()
    let run = AgentRunID()
    let snapshot = receipt()
    try await ledger.record(snapshot, runID: run)
    await #expect(throws: MacToolError.accessibilityObservationStale) {
      try await ledger.validate(
        observationID: snapshot.observationID, bundleIdentifier: snapshot.bundleIdentifier,
        selector: .init(path: "0.1"), runID: AgentRunID())
    }
    await #expect(throws: MacToolError.accessibilityObservationStale) {
      try await ledger.validate(
        observationID: snapshot.observationID, bundleIdentifier: "com.hex.other",
        selector: .init(path: "0.1"), runID: run)
    }
    let selected = try await ledger.take(
      observationID: snapshot.observationID, bundleIdentifier: snapshot.bundleIdentifier,
      selector: .init(title: "Apply"), runID: run)
    #expect(selected.path == "0.1")
    await #expect(throws: MacToolError.accessibilityObservationStale) {
      try await ledger.take(
        observationID: snapshot.observationID, bundleIdentifier: snapshot.bundleIdentifier,
        selector: .init(path: "0.1"), runID: run)
    }
  }

  @Test
  func freshnessExpiresAndNewObservationReplacesOldReceipt() async throws {
    let clock = OSAllocatedUnfairLock(initialState: UInt64(100))
    let ledger = MacAccessibilityObservationLedger(
      lifetimeNanoseconds: 20, now: { clock.withLock { $0 } })
    let run = AgentRunID()
    let first = receipt()
    let second = receipt()
    try await ledger.record(first, runID: run)
    try await ledger.record(second, runID: run)
    await #expect(throws: MacToolError.accessibilityObservationStale) {
      try await ledger.validate(
        observationID: first.observationID, bundleIdentifier: first.bundleIdentifier,
        selector: .init(path: "0.1"), runID: run)
    }
    clock.withLock { $0 = 120 }
    await #expect(throws: MacToolError.accessibilityObservationStale) {
      try await ledger.validate(
        observationID: second.observationID, bundleIdentifier: second.bundleIdentifier,
        selector: .init(path: "0.1"), runID: run)
    }
  }

  @Test
  func exactObservedSelectorRejectsUnknownAndAmbiguousTargets() async throws {
    let ledger = MacAccessibilityObservationLedger()
    let run = AgentRunID()
    let snapshot = receipt(elements: [
      .init(path: "0.1", role: "AXButton", title: "Apply"),
      .init(path: "0.2", role: "AXButton", title: "Apply"),
    ])
    try await ledger.record(snapshot, runID: run)
    await #expect(throws: MacToolError.accessibilityElementAmbiguous) {
      try await ledger.validate(
        observationID: snapshot.observationID, bundleIdentifier: snapshot.bundleIdentifier,
        selector: .init(title: "Apply"), runID: run)
    }
    await #expect(throws: MacToolError.accessibilityElementNotFound) {
      try await ledger.validate(
        observationID: snapshot.observationID, bundleIdentifier: snapshot.bundleIdentifier,
        selector: .init(path: "0.9"), runID: run)
    }
    let selected = try await ledger.validate(
      observationID: snapshot.observationID, bundleIdentifier: snapshot.bundleIdentifier,
      selector: .init(title: "Apply", occurrence: 1), runID: run)
    #expect(selected.path == "0.2")
  }

  private func receipt(
    elements: [MacAccessibilityElementSnapshot] = [
      .init(path: "0.1", role: "AXButton", title: "Apply")
    ]
  ) -> MacAccessibilitySnapshot {
    MacAccessibilitySnapshot(
      bundleIdentifier: "com.hex.fixture", applicationName: "Fixture", processIdentifier: 42,
      elements: elements, isTruncated: false)
  }
}
