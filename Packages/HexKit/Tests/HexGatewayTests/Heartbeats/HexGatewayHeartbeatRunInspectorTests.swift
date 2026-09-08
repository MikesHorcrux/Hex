import Foundation
import HexCore
import HexGatewayKit
import HexIPC
import Testing

@Suite("Scheduled failure receipt previews")
struct HexGatewayHeartbeatRunInspectorTests {
  @Test(arguments: ["A short original failure.", String(repeating: "🐑é", count: 1_200)])
  func failurePreviewFitsReceiptStoreWhileOriginalJournalRemainsComplete(message: String)
    async throws
  {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent(
        "hex-heartbeat-failure-preview-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)])
    defer { try? FileManager.default.removeItem(at: directory) }
    let composition = try await HexGatewayComposition.openInert(
      databaseURL: directory.appendingPathComponent("journal.sqlite"))
    let store = try await SQLiteHexHeartbeatStore.open(
      databaseURL: directory.appendingPathComponent("schedules.sqlite"))
    let client = HexGatewayClient(transport: composition.transport)
    let claimedAt = Date().addingTimeInterval(-120)
    let schedule = try HexHeartbeatSchedule(
      name: "Keep the complete failure",
      instruction: "Report a failure.", intervalSeconds: 60, nextDueAt: claimedAt)
    let runID = AgentRunID()
    let lease = HexHeartbeatLease(
      occurrence: schedule.occurrence(), claimedAt: claimedAt,
      expiresAt: claimedAt.addingTimeInterval(30), runID: runID)
    let originalFailure = AgentFailure(code: .provider, message: message, isRetryable: true)
    do {
      try await store.replace(HexHeartbeatStoreSnapshot(schedules: [schedule]))
      #expect(try await store.claim(lease, at: claimedAt) == .claimed)
      let start = try await composition.journal.append(.runStarted, to: runID)
      let terminal = try await composition.journal.append(.runFailed(originalFailure), to: runID)
      _ = try await client.connect()
      let inspected = try await HexGatewayHeartbeatRunInspector(client: client).inspect(lease)
      guard case .terminal(let outcome, let identity) = inspected else {
        throw FixtureError.missingTerminal
      }
      let failure = try #require(outcome.failure)
      #expect(outcome.kind == .failed)
      #expect(failure.retryable)
      #expect(failure.message.utf8.count <= GatewayHeartbeatOutcome.maximumFailureMessageBytes)
      #expect(!failure.message.contains("\u{FFFD}"))
      if message.utf8.count > GatewayHeartbeatOutcome.maximumFailureMessageBytes {
        #expect(
          failure.message.hasSuffix(
            "[Preview truncated. Open saved run activity for the full failure.]"))
        #expect(failure.message.hasPrefix("🐑é"))
      } else {
        #expect(failure.message == message)
      }
      #expect(identity.firstEventID == start.id)
      #expect(identity.terminalSequence == terminal.sequence)
      let completion = HexHeartbeatCompletion(
        lease: lease, outcome: outcome,
        nextDueAt: Date().addingTimeInterval(60), journal: identity)
      #expect(try await store.reconcile(completion, at: Date()) == .completed)
      let saved = try #require(try await store.receipts().receipts.first)
      #expect(saved.outcome == outcome)
      #expect(saved.journal == identity)
      let original = try await client.readRunHistory(
        GatewayRunHistoryRequest(
          runID: runID,
          firstEventID: identity.firstEventID, afterSequence: 0,
          throughSequence: identity.terminalSequence))
      #expect(original.records == [start, terminal])
      #expect(original.records.last?.event == .runFailed(originalFailure))
      try await client.disconnect()
      try await store.close()
      try await composition.close()
    } catch {
      try? await client.disconnect()
      try? await store.close()
      try? await composition.close()
      throw error
    }
  }

  private enum FixtureError: Error { case missingTerminal }
}
