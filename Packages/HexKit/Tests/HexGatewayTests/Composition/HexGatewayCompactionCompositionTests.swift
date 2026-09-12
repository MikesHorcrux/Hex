import Foundation
import HexCore
import HexGatewayKit
import HexIPC
import HexPersistence
import Testing

@Suite("Gateway compaction composition")
struct HexGatewayCompactionCompositionTests {
  @Test
  func compactionSurvivesRuntimeSQLiteAndGatewayReplay() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hex-gateway-compaction-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)])
    defer { try? FileManager.default.removeItem(at: directory) }
    let journalConfiguration = SQLiteAgentEventJournalConfiguration(
      databaseURL: directory.appendingPathComponent("journal.sqlite", isDirectory: false))
    // Retain the entire run, including the original-message events preceding compaction. The
    // standard eight-record window intentionally cannot promise replay from the run's beginning.
    let gatewayConfiguration = try #require(
      GatewayConfiguration(
        maximumWireBytes: 262_144, maximumRetainedRecordsPerRun: 64,
        subscriberBufferCapacity: 64))
    let provider = UsageReportingProvider()
    let knowledge = HexSelfKnowledge(
      journalFileURL: journalConfiguration.databaseURL,
      runningExecutableURL: nil, runningBundleURL: nil, sourceRootHintURL: nil)
    let composition = try await HexGatewayComposition.open(
      configuration: HexGatewayCompositionConfiguration(
        journalConfiguration: journalConfiguration,
        inferenceProvider: provider,
        toolExecutor: GatewayTestToolExecutor(),
        authorizationProvider: GatewayTestAuthorizationProvider(),
        gatewayConfiguration: gatewayConfiguration,
        selfKnowledge: knowledge))
    let runID = AgentRunID()
    let original = history()
    let request = GatewayStartRunRequest(
      runID: runID, modelID: provider.modelID, initialMessages: original, toolChoice: .none)
    let records: [AgentEventRecord]
    do {
      _ = try await composition.transport.handshake(
        GatewayHandshakeRequest(clientID: GatewayClientID()))
      let start = try await composition.transport.startRun(request)
      let invocationID = try #require(start.invocationID)
      let envelopes = try await collect(
        composition.transport.eventRecords(
          after: GatewayEventCursor(runID: runID, invocationID: invocationID)))
      records = envelopes.map(\.record)
      #expect(envelopes.allSatisfy { $0.invocationID == invocationID })
      #expect(records.allSatisfy { $0.runID == runID && $0.schemaVersion == 1 })
      #expect(records.map(\.sequence) == records.indices.map { UInt64($0 + 1) })
      #expect(records.first?.event == .runStarted)
      #expect(records.last?.event == .runCompleted)

      let started = try #require(records.first { $0.event == .contextCompactionStarted })
      #expect(records.filter { $0.event == .contextCompactionStarted }.count == 1)
      let compactedRecords = records.filter {
        if case .contextCompacted = $0.event { return true }
        return false
      }
      #expect(compactedRecords.count == 1)
      let compactedRecord = try #require(compactedRecords.first)
      guard case .contextCompacted(let compaction) = compactedRecord.event else {
        Issue.record("Expected the typed runtime-produced context compaction.")
        try await composition.close()
        return
      }
      #expect(compaction.ownerRunID == runID)
      #expect(
        compaction.sourceMessageIDs == original.prefix(compaction.sourceMessageIDs.count).map(\.id))
      #expect(!compaction.sourceMessageIDs.isEmpty)
      #expect(compaction.sourceMessageIDs.count < original.count)
      #expect(compaction.sourceMessageIDs.count.isMultiple(of: 2))
      #expect(compaction.summaryMessage.id == MessageID(rawValue: compaction.id))
      #expect(compaction.summaryMessage.role == .user)
      #expect(compaction.summaryText == "done")
      #expect(compaction.providerID == provider.descriptor.id)
      #expect(compaction.modelID == provider.modelID)
      #expect(compaction.estimatedTokensAfter < compaction.estimatedTokensBefore)
      let summaryCalls = await provider.callCount() - 1
      #expect(summaryCalls > 0)
      #expect(compaction.inferenceCalls == summaryCalls)
      #expect(compaction.reportedTokens == UInt64(summaryCalls) * 104)
      let metadata = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(compaction)) as? [String: Any])
      #expect((metadata["inferenceCalls"] as? NSNumber)?.intValue == summaryCalls)
      #expect((metadata["reportedTokens"] as? NSNumber)?.uint64Value == UInt64(summaryCalls) * 104)

      let primaryRecords = records.filter {
        if case .inferenceRequested = $0.event { return true }
        return false
      }
      #expect(primaryRecords.count == 1)
      let primaryRecord = try #require(primaryRecords.first)
      guard case .inferenceRequested(let primary) = primaryRecord.event else {
        Issue.record("Expected the typed primary inference request.")
        try await composition.close()
        return
      }
      #expect(started.sequence < compactedRecord.sequence)
      #expect(compactedRecord.sequence < primaryRecord.sequence)
      #expect(primary.previousProviderResponseID == nil)
      #expect(primary.modelID == provider.modelID)
      let trusted = Array(primary.messages.prefix(2))
      #expect(trusted.map(\.role) == [.developer, .developer])
      #expect(trusted.first?.content == HexAgentOperatingContract().message.content)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      let snapshot = try encoder.encode(
        knowledge.snapshot(
          provider: provider.descriptor, modelID: request.modelID,
          workingDirectory: request.workingDirectory, options: request.options))
      #expect(
        trusted.last?.content == [
          .text(HexSelfOperatingManual().summary + "\n" + String(decoding: snapshot, as: UTF8.self))
        ])
      #expect(
        Array(primary.messages.dropFirst(2))
          == [compaction.summaryMessage] + original.dropFirst(compaction.sourceMessageIDs.count))
      #expect(primary.messages.last == original.last)

      let journaledMessages = records.compactMap { record -> Message? in
        guard case .messageAppended(let message) = record.event else { return nil }
        return message
      }
      #expect(Array(journaledMessages.prefix(original.count)) == original)
      #expect(journaledMessages.count == original.count + 1)
      #expect(!journaledMessages.contains { $0.role == .developer })
      #expect(
        try await composition.journal.records(for: runID, after: nil, limit: 128) == records)

      let replay = try await collect(
        composition.transport.eventRecords(
          after: GatewayEventCursor(
            runID: runID, invocationID: invocationID, sequence: started.sequence)))
      let expectedSuffix = envelopes.filter { $0.record.sequence > started.sequence }
      #expect(replay == expectedSuffix)
      #expect(replay.first?.record == compactedRecord)
      #expect(replay.first?.record.event == .contextCompacted(compaction))
      #expect(replay.last?.record.event == .runCompleted)
      try await composition.close()
    } catch {
      try? await composition.close()
      throw error
    }

    let reopened = try await SQLiteAgentEventJournal.open(configuration: journalConfiguration)
    do {
      #expect(try await reopened.records(for: runID, after: nil, limit: 128) == records)
      try await reopened.close()
    } catch {
      try? await reopened.close()
      throw error
    }
  }

  private func history() -> [Message] {
    (0..<10).flatMap { index in
      [
        Message(
          role: .user, content: [.text("Question \(index) " + String(repeating: "x", count: 4_000))]
        ),
        Message(
          role: .assistant,
          content: [.text("Answer \(index) " + String(repeating: "y", count: 4_000))]),
      ]
    } + [
      Message(
        role: .user, content: [.text("Continue the current task without changing its scope.")])
    ]
  }

  private func collect(_ stream: AsyncThrowingStream<GatewayEventEnvelope, any Error>) async throws
    -> [GatewayEventEnvelope]
  {
    var envelopes: [GatewayEventEnvelope] = []
    for try await envelope in stream { envelopes.append(envelope) }
    return envelopes
  }

  private actor UsageReportingProvider: InferenceProvider {
    nonisolated let modelID = ModelID(rawValue: "compaction-usage-model")
    nonisolated let descriptor = ProviderDescriptor(
      id: ProviderID(rawValue: "compaction-usage-provider"),
      displayName: "Offline compaction usage fixture",
      capabilities: [.textInput, .streaming, .toolCalling])
    private var calls = 0

    func availableModels() async throws -> [ModelDescriptor] {
      try Task.checkCancellation()
      return [
        ModelDescriptor(
          id: modelID, providerID: descriptor.id, displayName: "Offline usage model",
          capabilities: descriptor.capabilities, maxOutputTokens: 256)
      ]
    }

    func stream(_ request: InferenceRequest) async throws -> InferenceStream {
      try Task.checkCancellation()
      calls += 1
      let events = AsyncThrowingStream<InferenceStreamEvent, any Error> { continuation in
        continuation.yield(.started(providerResponseID: "offline-response"))
        continuation.yield(.textDelta("done"))
        continuation.yield(.usage(InferenceUsage(inputTokens: 100, outputTokens: 4)))
        continuation.yield(.completed(.stop))
        continuation.finish()
      }
      return InferenceStream(events: events, onCancellation: {}, waitForTermination: {})
    }

    func callCount() -> Int { calls }
  }
}
