import Foundation
import HexCapabilities
import HexCore
import HexIPC
import HexPersistence
import Testing

@testable import HexGatewayKit

@Suite("Durable scheduled results through the real runtime")
struct HexHeartbeatResultsWorkflowTests {
  @Test
  func deletedScheduleStillOpensItsOriginalReplyAndProcessOutputAfterReopen() async throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("hex-scheduled-result-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)])
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("schedules.sqlite")
    let outputStore = try FileArtifactStore(rootURL: directory.appendingPathComponent("artifacts"))
    let call = ToolCall(
      id: ToolCallID(rawValue: "scheduled-process"), name: "process_run",
      arguments: [
        "executable": .string("/bin/sh"),
        "arguments": .array([
          .string("-c"), .string("printf 'ran\\n' >> occurrence-count; /usr/bin/seq 1 12000"),
        ]),
        "timeout_seconds": .integer(10),
      ])
    let provider = GatewayTestInferenceProvider(toolCall: call)
    let tools = try HostToolExecutor(tools: [
      ProcessRunTool(executor: POSIXProcessExecutor(artifactWriter: outputStore))
    ])
    let config = HexGatewayCompositionConfiguration(
      journalConfiguration: SQLiteAgentEventJournalConfiguration(
        databaseURL: directory.appendingPathComponent("journal.sqlite")),
      inferenceProvider: provider, toolExecutor: tools,
      authorizationProvider: GatewayTestAuthorizationProvider(),
      enforcedWorkingDirectory: directory, artifactWriter: outputStore, artifactReader: outputStore)
    let composition = try await HexGatewayComposition.open(configuration: config)
    let client = HexGatewayClient(transport: composition.transport)
    let store = try await SQLiteHexHeartbeatStore.open(databaseURL: storeURL)
    let schedule = try HexHeartbeatSchedule(
      name: "Keep this result", instruction: "Generate the scheduled output and report the result.",
      intervalSeconds: 60, nextDueAt: Date().addingTimeInterval(-1))
    let receipt: HexHeartbeatOccurrenceReceipt
    do {
      _ = try await client.connect()
      let policy = HexHeartbeatAuthorizationPolicy(
        interactivePrompter: HexGatewayAuthorizationBroker())
      let runner = try HexGatewayHeartbeatRunner(
        client: client, authorizationPolicy: policy, modelID: provider.modelID,
        workspaceRoot: directory)
      let scheduler = HexHeartbeatScheduler(
        store: store, runner: runner, runInspector: HexGatewayHeartbeatRunInspector(client: client))
      try await scheduler.add(schedule)
      let reports = try await scheduler.runDue(at: Date())
      #expect(reports.count == 1)
      #expect(reports.first?.outcome.kind == .succeeded)
      receipt = try #require(try await scheduler.receipts().receipts.first)
      #expect(receipt.occurrence == schedule.occurrence())
      #expect(receipt.runID != nil)
      #expect(receipt.journal?.runID == receipt.runID)
      try await scheduler.remove(schedule.id)
      #expect(try await scheduler.snapshot().schedules.isEmpty)
      #expect(try await scheduler.receipts().receipts == [receipt])
      try await client.disconnect()
      try await composition.close()
      try await store.close()
    } catch {
      try? await client.disconnect()
      try? await composition.close()
      try? await store.close()
      throw error
    }

    let reopenedStore = try await SQLiteHexHeartbeatStore.open(databaseURL: storeURL)
    let reopenedComposition = try await HexGatewayComposition.open(configuration: config)
    let readClient = HexGatewayClient(transport: reopenedComposition.transport)
    do {
      #expect(try await reopenedStore.load().schedules.isEmpty)
      let restored = try #require(
        try await reopenedStore.receipts(scheduleID: nil, after: nil, limit: 20).receipts.first)
      #expect(restored == receipt)
      _ = try await readClient.connect()
      let runID = try #require(restored.runID)
      let anchor = try #require(restored.journal)
      let recovery = try await readClient.recoverRun(GatewayRunRecoveryRequest(runID: runID))
      guard case .journaled(let snapshot) = recovery.disposition else {
        Issue.record("Reopening a result must read its journal, not manufacture a new live run.")
        try await readClient.disconnect()
        try await reopenedComposition.close()
        try await reopenedStore.close()
        return
      }
      #expect(snapshot.firstEventID == anchor.firstEventID)
      #expect(snapshot.latestSequence == anchor.terminalSequence)
      var records: [AgentEventRecord] = []
      var after: UInt64 = 0
      repeat {
        let page = try await readClient.readRunHistory(
          GatewayRunHistoryRequest(
            runID: runID, firstEventID: anchor.firstEventID, afterSequence: after,
            throughSequence: anchor.terminalSequence, limit: 32))
        records.append(contentsOf: page.records)
        guard let next = page.nextAfterSequence else { break }
        after = next
      } while records.count < 256
      #expect(records.last?.event == .runCompleted)
      #expect(
        records.contains {
          if case .messageAppended(let message) = $0.event {
            return message.role == .assistant && message.content == [.text("done")]
          }
          return false
        })
      let result = try #require(
        records.compactMap { record -> ToolResult? in
          if case .toolFinished(let value) = record.event { return value }
          return nil
        }.first)
      let artifact = try #require(result.artifacts.first)
      let output = try await readClient.readArtifact(
        GatewayArtifactReadRequest(reference: artifact, offset: 0, maximumBytes: 65_536))
      #expect(String(data: output.data, encoding: .utf8) == (1...12_000).map { "\($0)\n" }.joined())
      #expect(output.nextOffset == nil)
      #expect(
        try String(
          contentsOf: directory.appendingPathComponent("occurrence-count"), encoding: .utf8)
          == "ran\n")
      try await readClient.disconnect()
      try await reopenedComposition.close()
      try await reopenedStore.close()
    } catch {
      try? await readClient.disconnect()
      try? await reopenedComposition.close()
      try? await reopenedStore.close()
      throw error
    }
  }
}
