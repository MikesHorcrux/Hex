import Foundation
import HexCapabilities
import HexCore
import HexGatewayKit
import HexIPC
import HexPersistence
import HexRuntime
import Testing

@Suite("Gateway composition")
struct HexGatewayCompositionTests {
  @Test
  func opensConnectedGraphAndPublishesDurableRunEvents() async throws {
    let runID = AgentRunID()
    let provider = GatewayTestInferenceProvider()
    let journal = try await SQLiteAgentEventJournal.open(
      configuration: SQLiteAgentEventJournalConfiguration(
        databaseURL: Self.temporaryDatabaseURL()
      )
    )
    let configuration = HexGatewayCompositionConfiguration(
      journal: journal,
      inferenceProvider: provider,
      toolExecutor: GatewayTestToolExecutor(),
      authorizationProvider: GatewayTestAuthorizationProvider()
    )
    let composition = try await HexGatewayComposition.open(configuration: configuration)

    _ = try await composition.transport.handshake(
      GatewayHandshakeRequest(clientID: GatewayClientID())
    )
    let request = GatewayStartRunRequest(
      runID: runID,
      modelID: provider.modelID,
      initialMessages: [Message(role: .user, content: [.text("hello")])],
      toolChoice: .none
    )
    let start = try await composition.transport.startRun(request)
    let invocationID = try #require(start.invocationID)
    let stream = try await composition.transport.eventRecords(
      after: GatewayEventCursor(runID: runID, invocationID: invocationID)
    )
    var envelopes: [GatewayEventEnvelope] = []
    for try await envelope in stream {
      envelopes.append(envelope)
    }

    #expect(
      envelopes.map { $0.record.sequence }
        == Array(0..<envelopes.count).map { UInt64($0 + 1) }
    )
    #expect(envelopes.first?.record.runID == runID)
    #expect(envelopes.last?.record.event == .runCompleted)
    #expect(
      try await composition.journal.records(for: runID, after: nil, limit: 128)
        == envelopes.map(\.record)
    )

    try await composition.close()
    try await journal.close()
  }

  @Test
  func rejectsMalformedDurableRecordBeforePublishingIt() async throws {
    let journal = GatewayMalformedEventJournal()
    let driver = HexGatewayRunDriverAdapter(
      inferenceProvider: GatewayTestInferenceProvider(),
      toolExecutor: GatewayTestToolExecutor(),
      authorizationProvider: GatewayTestAuthorizationProvider(),
      journal: journal
    )
    let request = GatewayStartRunRequest(
      runID: AgentRunID(),
      modelID: GatewayTestInferenceProvider().modelID,
      initialMessages: [Message(role: .user, content: [.text("hello")])],
      toolChoice: .none
    )
    let collector = GatewayEventCollector()

    do {
      try await driver.run(request) { record in
        await collector.append(record)
      }
      Issue.record("Expected a malformed durable record to fail the run.")
    } catch let error as AgentRuntimeError {
      guard case .journalFailure = error else {
        Issue.record("Expected a journal failure, received: \(error).")
        return
      }
    }

    #expect(await collector.records().isEmpty)
  }

  @Test
  func enforcedWorkingDirectoryReplacesMissingAndClientRequestedDirectories() async throws {
    let tool = ToolDefinition(
      name: "workspace_probe",
      description: "Records the gateway-owned working directory.",
      inputSchema: ["type": .string("object")]
    )
    let call = ToolCall(
      id: ToolCallID(rawValue: "workspace-probe"),
      name: tool.name,
      arguments: [:]
    )
    let provider = GatewayTestInferenceProvider(toolCall: call)
    let executor = GatewayTestToolExecutor(tool: tool)
    let journal = try await SQLiteAgentEventJournal.open(
      configuration: SQLiteAgentEventJournalConfiguration(
        databaseURL: Self.temporaryDatabaseURL()
      )
    )
    let enforcedDirectory = URL(
      fileURLWithPath: "/tmp/hex-resident-workspace",
      isDirectory: true
    )
    let configuration = HexGatewayCompositionConfiguration(
      journal: journal,
      inferenceProvider: provider,
      toolExecutor: executor,
      authorizationProvider: GatewayTestAuthorizationProvider(),
      enforcedWorkingDirectory: enforcedDirectory
    )
    let composition = try await HexGatewayComposition.open(configuration: configuration)

    for requestedDirectory in [
      nil,
      URL(fileURLWithPath: "/tmp/client-requested-workspace", isDirectory: true),
    ] {
      let request = GatewayStartRunRequest(
        runID: AgentRunID(),
        modelID: provider.modelID,
        initialMessages: [Message(role: .user, content: [.text("inspect workspace")])],
        workingDirectory: requestedDirectory
      )
      try await composition.runDriver.run(request) { _ in }
    }

    #expect(
      await executor.contexts().map(\.workingDirectory)
        == [enforcedDirectory, enforcedDirectory]
    )
    try await composition.close()
    try await journal.close()
  }

  private static func temporaryDatabaseURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("hex-gateway-composition-\(UUID().uuidString)")
      .appendingPathComponent("journal.sqlite")
  }
}
