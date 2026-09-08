import Foundation
import HexCore
import HexIPC
import Testing

@Suite("Read-only gateway run recovery")
struct GatewayRunRecoveryTests {
  @Test
  func journaledAndUnknownLookupsNeverStartTheDriver() async throws {
    let runID = GatewayTestValues.runID(180)
    let records = history(runID: runID)
    let reader = Reader(records: records)
    let driver = ControllableGatewayRunDriver()
    let service = HexGatewayService(driver: driver, historyReader: reader)
    let client = HexGatewayClient(transport: InProcessHexGatewayTransport(service: service))
    let connection = try await client.connect()
    let response = try await client.recoverRun(GatewayRunRecoveryRequest(runID: runID))
    #expect(response.gatewayInstanceID == connection.response.gatewayInstanceID)
    #expect(response.runID == runID)
    guard case .journaled(let snapshot) = response.disposition else {
      Issue.record("Expected durable-only recovery without an invented invocation.")
      return
    }
    #expect(snapshot.firstEventID == records.first?.id)
    #expect(snapshot.terminalRecord == records.last)
    let unknown = AgentRunID()
    #expect(
      try await client.recoverRun(GatewayRunRecoveryRequest(runID: unknown)).disposition == .unknown
    )
    #expect(await driver.invocationCount(for: runID) == 0)
    #expect(await driver.invocationCount(for: unknown) == 0)
  }

  @Test
  func historyPagesAreByteBoundedContiguousAndFixedToTheRequestedSnapshot() async throws {
    let runID = GatewayTestValues.runID(181)
    let records = history(runID: runID, messageCount: 20, textSize: 200)
    let reader = Reader(records: records)
    let configuration = try #require(
      GatewayConfiguration(
        maximumWireBytes: 4_096, maximumRetainedRecordsPerRun: 8, subscriberBufferCapacity: 8))
    let driver = ControllableGatewayRunDriver()
    let service = HexGatewayService(
      driver: driver, configuration: configuration, historyReader: reader)
    let client = HexGatewayClient(
      transport: InProcessHexGatewayTransport(service: service, configuration: configuration),
      configuration: configuration)
    _ = try await client.connect()
    let anchor = try #require(records.first?.id)
    var after: UInt64 = 0
    var restored: [AgentEventRecord] = []
    var pages = 0
    while after < UInt64(records.count) {
      let page = try await client.readRunHistory(
        GatewayRunHistoryRequest(
          runID: runID, firstEventID: anchor, afterSequence: after,
          throughSequence: UInt64(records.count), limit: 32))
      #expect(page.runID == runID)
      #expect(page.firstEventID == anchor)
      #expect(page.afterSequence == after)
      #expect(page.throughSequence == UInt64(records.count))
      #expect(!page.records.isEmpty)
      let codec = GatewayWireCodec(configuration: configuration)
      _ = try codec.encode(
        GatewayXPCResponseEnvelope(operation: .readRunHistory, body: codec.encode(page)))
      restored += page.records
      after = try #require(page.records.last?.sequence)
      #expect(page.nextAfterSequence == (after < UInt64(records.count) ? after : nil))
      pages += 1
      try #require(pages <= records.count)
    }
    #expect(pages > 1)
    #expect(restored == records)
    #expect(await driver.invocationCount(for: runID) == 0)
  }

  @Test
  func wrongAnchorAndFutureCursorFailWithoutReturningHistory() async throws {
    let runID = GatewayTestValues.runID(182)
    let records = history(runID: runID)
    let service = HexGatewayService(
      driver: ControllableGatewayRunDriver(), historyReader: Reader(records: records))
    let client = HexGatewayClient(transport: InProcessHexGatewayTransport(service: service))
    _ = try await client.connect()
    for request in [
      GatewayRunHistoryRequest(
        runID: runID, firstEventID: AgentEventID(), afterSequence: 0, throughSequence: 3),
      GatewayRunHistoryRequest(
        runID: runID, firstEventID: records[0].id, afterSequence: 0, throughSequence: 4),
      GatewayRunHistoryRequest(
        runID: runID, firstEventID: records[0].id, afterSequence: 3, throughSequence: 2),
    ] {
      do {
        _ = try await client.readRunHistory(request)
        Issue.record("Expected an invalid recovery cursor to fail.")
      } catch let failure as GatewayFailure { #expect(failure.code == .invalidCursor) }
    }
  }

  @Test
  func explicitDurableCheckpointAttachesToKnownInvocationWithoutStartingAgain() async throws {
    let runID = GatewayTestValues.runID(183)
    let records = history(runID: runID, messageCount: 3)
    let configuration = try #require(
      GatewayConfiguration(
        maximumWireBytes: 32_768, maximumRetainedRecordsPerRun: 2, subscriberBufferCapacity: 2))
    let driver = ControllableGatewayRunDriver()
    let service = HexGatewayService(
      driver: driver, configuration: configuration, historyReader: Reader(records: records))
    let client = HexGatewayClient(
      transport: InProcessHexGatewayTransport(service: service, configuration: configuration),
      configuration: configuration)
    _ = try await client.connect()
    let start = try await client.startRun(GatewayTestValues.request(runID: runID))
    let invocationID = try #require(start.invocationID)
    await driver.waitUntilStarted(runID)
    for record in records { await driver.yieldAndWait(record) }
    await driver.finish(runID)
    await driver.waitUntilStopped(runID)
    let recovery = try await client.recoverRun(GatewayRunRecoveryRequest(runID: runID))
    guard case .resident(let snapshot, let floor, _) = recovery.disposition else {
      Issue.record("Expected a remembered resident invocation.")
      return
    }
    #expect(snapshot.invocationID == invocationID)
    #expect(floor == 3)
    let stream = try await client.eventRecords(
      for: runID, invocationID: invocationID, afterSequence: 3)
    var applied: [AgentEventRecord] = []
    for try await envelope in stream {
      #expect(try await client.shouldApply(envelope))
      applied.append(envelope.record)
      try await client.acknowledge(envelope)
    }
    #expect(applied == Array(records.suffix(2)))
    #expect(await client.acknowledgedCursor(for: runID, invocationID: invocationID).sequence == 5)
    #expect(await driver.invocationCount(for: runID) == 1)
  }

  private func history(runID: AgentRunID, messageCount: Int = 1, textSize: Int = 10)
    -> [AgentEventRecord]
  {
    let events: [AgentEvent] =
      [.runStarted]
      + (0..<messageCount).map { _ in
        .messageAppended(
          Message(role: .user, content: [.text(String(repeating: "x", count: textSize))]))
      } + [.runCompleted]
    return events.enumerated().map {
      GatewayTestValues.record(runID: runID, sequence: UInt64($0.offset + 1), event: $0.element)
    }
  }

  private actor Reader: HexGatewayRunHistoryReading {
    let stored: [AgentEventRecord]
    init(records: [AgentEventRecord]) { stored = records }
    func snapshot(for runID: AgentRunID) async throws -> GatewayJournalRunSnapshot? {
      guard let first = stored.first, first.runID == runID, let last = stored.last else {
        return nil
      }
      return GatewayJournalRunSnapshot(
        runID: runID, firstEventID: first.id, latestSequence: last.sequence, terminalRecord: last)
    }
    func records(
      for runID: AgentRunID, after: UInt64, through: UInt64, limit: Int, maximumBytes: Int
    ) async throws -> [AgentEventRecord] {
      Array(
        stored.filter { $0.runID == runID && $0.sequence > after && $0.sequence <= through }.prefix(
          limit))
    }
  }
}
