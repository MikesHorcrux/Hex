import Foundation
@testable import HexCapabilities
import HexCore
import Testing

@Suite("Process authorization ledger")
struct ProcessAuthorizationLedgerTests {
  @Test
  func executionTakesEachAuthorizationSnapshotOnlyOnce() async throws {
    let request = ProcessExecutionRequest(
      executable: URL(fileURLWithPath: "/usr/bin/true"),
      arguments: [],
      workingDirectory: URL(fileURLWithPath: "/private/tmp"),
      timeoutSeconds: 5
    )
    let identity = try ProcessExecutionIdentity.capture(for: request)
    let ledger = ProcessAuthorizationLedger()
    let runID = AgentRunID()
    let toolCallID = ToolCallID(rawValue: "ledger-single-use")

    try await ledger.record(
      runID: runID,
      toolCallID: toolCallID,
      request: request,
      identity: identity
    )
    #expect(await ledger.take(runID: runID, toolCallID: toolCallID)?.request == request)
    #expect(await ledger.take(runID: runID, toolCallID: toolCallID) == nil)
  }

  @Test
  func rejectsOneSnapshotThatExceedsTheAggregateByteBudget() async throws {
    let request = ProcessExecutionRequest(
      executable: URL(fileURLWithPath: "/usr/bin/true"),
      arguments: [String(repeating: "x", count: 9 * 1_024 * 1_024)],
      workingDirectory: URL(fileURLWithPath: "/private/tmp"),
      timeoutSeconds: 5
    )
    let identity = try ProcessExecutionIdentity.capture(for: request)
    let ledger = ProcessAuthorizationLedger()
    let runID = AgentRunID()
    let toolCallID = ToolCallID(rawValue: "ledger-byte-bound")

    await #expect(throws: ProcessExecutionError.authorizationStateUnavailable) {
      try await ledger.record(
        runID: runID,
        toolCallID: toolCallID,
        request: request,
        identity: identity
      )
    }
    #expect(await ledger.take(runID: runID, toolCallID: toolCallID) == nil)
  }

  @Test
  func hostRunCleanupRemovesAllPendingSnapshotsForThatRun() async throws {
    let request = ProcessExecutionRequest(
      executable: URL(fileURLWithPath: "/usr/bin/true"),
      arguments: [],
      workingDirectory: URL(fileURLWithPath: "/private/tmp"),
      timeoutSeconds: 5
    )
    let identity = try ProcessExecutionIdentity.capture(for: request)
    let ledger = ProcessAuthorizationLedger()
    let runID = AgentRunID()

    try await ledger.record(
      runID: runID,
      toolCallID: ToolCallID(rawValue: "ledger-cleanup-1"),
      request: request,
      identity: identity
    )
    try await ledger.record(
      runID: runID,
      toolCallID: ToolCallID(rawValue: "ledger-cleanup-2"),
      request: request,
      identity: identity
    )
    await ledger.remove(runID: runID)

    #expect(
      await ledger.take(
        runID: runID,
        toolCallID: ToolCallID(rawValue: "ledger-cleanup-1")
      ) == nil
    )
    #expect(
      await ledger.take(
        runID: runID,
        toolCallID: ToolCallID(rawValue: "ledger-cleanup-2")
      ) == nil
    )
  }
}
