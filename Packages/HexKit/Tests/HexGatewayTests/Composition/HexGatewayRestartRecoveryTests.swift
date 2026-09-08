import Foundation
import HexCore
import HexGatewayKit
import HexIPC
import HexPersistence
import Testing

@Suite("Gateway durable restart recovery")
struct HexGatewayRestartRecoveryTests {
  @Test
  func newGatewayRecoversInterruptedEvidenceWithoutStartingInferenceOrReplayingTools() async throws
  {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hex-recovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configuration = SQLiteAgentEventJournalConfiguration(
      databaseURL: directory.appendingPathComponent("journal.sqlite"))
    let journal = try await SQLiteAgentEventJournal.open(configuration: configuration)
    let runID = AgentRunID()
    let call = ToolCall(
      id: ToolCallID(rawValue: "uncertain-effect"), name: "write_file", arguments: [:])
    let first = try await journal.append(.runStarted, to: runID)
    _ = try await journal.append(
      .messageAppended(Message(role: .user, content: [.text("Original task")])), to: runID)
    _ = try await journal.append(.toolStarted(call), to: runID)
    try await journal.close()
    let provider = CountingProvider()
    let executor = GatewayTestToolExecutor()
    var previousRecords: [AgentEventRecord]?
    var priorInstance: GatewayInstanceID?
    for _ in 0..<2 {
      let composition = try await HexGatewayComposition.open(
        configuration: HexGatewayCompositionConfiguration(
          journalConfiguration: configuration, inferenceProvider: provider, toolExecutor: executor,
          authorizationProvider: GatewayTestAuthorizationProvider()))
      let client = HexGatewayClient(transport: composition.transport)
      let connection = try await client.connect()
      if let priorInstance { #expect(connection.response.gatewayInstanceID != priorInstance) }
      priorInstance = connection.response.gatewayInstanceID
      let recovery = try await client.recoverRun(GatewayRunRecoveryRequest(runID: runID))
      guard case .journaled(let snapshot) = recovery.disposition else {
        Issue.record("Expected durable-only recovery after helper replacement.")
        try await composition.close()
        return
      }
      #expect(snapshot.firstEventID == first.id)
      #expect(snapshot.latestSequence == 4)
      guard case .runFailed(let failure) = snapshot.terminalRecord?.event else {
        Issue.record("Expected the recovered interruption's durable failure.")
        try await composition.close()
        return
      }
      #expect(!failure.isRetryable)
      let page = try await client.readRunHistory(
        GatewayRunHistoryRequest(
          runID: runID, firstEventID: first.id, afterSequence: 0,
          throughSequence: snapshot.latestSequence))
      #expect(page.records.first == first)
      #expect(page.records.contains { $0.event == .toolStarted(call) })
      #expect(page.nextAfterSequence == nil)
      if let previousRecords { #expect(page.records == previousRecords) }
      previousRecords = page.records
      #expect(await provider.calls == 0)
      #expect(await executor.contexts().isEmpty)
      try await client.disconnect()
      try await composition.close()
    }
  }

  private actor CountingProvider: InferenceProvider {
    nonisolated let descriptor = GatewayTestInferenceProvider().descriptor
    var calls = 0
    func availableModels() async throws -> [ModelDescriptor] {
      calls += 1
      return try await GatewayTestInferenceProvider().availableModels()
    }
    func stream(_ request: InferenceRequest) async throws -> InferenceStream {
      calls += 1
      return try await GatewayTestInferenceProvider().stream(request)
    }
  }
}
