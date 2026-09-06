import Foundation
import HexCore
import HexIPC
import Testing

@Suite("Gateway context compaction events")
struct GatewayContextCompactionTests {
  @Test
  func compactionEventsRoundTripAndReplayInOrder() async throws {
    let runID = GatewayTestValues.runID(170)
    let compaction = try make(runID: runID)
    let events: [AgentEvent] = [
      .runStarted, .contextCompactionStarted, .contextCompacted(compaction), .runCompleted,
    ]
    let records = events.enumerated().map { index, event in
      GatewayTestValues.record(runID: runID, sequence: UInt64(index + 1), event: event)
    }
    let codec = GatewayWireCodec(configuration: .standard)
    for record in records { #expect(try codec.roundTrip(record) == record) }
    let client = HexGatewayClient(transport: MalformedEventGatewayTransport(records: records))
    _ = try await client.connect()
    let invocationID = GatewayTestValues.invocationID(170)
    let stream = try await client.eventRecords(for: runID, invocationID: invocationID)
    var applied: [AgentEventRecord] = []
    for try await envelope in stream {
      #expect(try await client.shouldApply(envelope))
      applied.append(envelope.record)
      try await client.acknowledge(envelope)
    }
    #expect(applied == records)
    #expect(await client.acknowledgedCursor(for: runID, invocationID: invocationID).sequence == 4)
  }

  @Test
  func clientRejectsCompactionThatClaimsAnotherOwnerBeforeApplyingIt() async throws {
    let runID = GatewayTestValues.runID(171)
    let records = [
      GatewayTestValues.record(runID: runID, sequence: 1, event: .runStarted),
      GatewayTestValues.record(runID: runID, sequence: 2, event: .contextCompactionStarted),
      GatewayTestValues.record(
        runID: runID, sequence: 3, event: .contextCompacted(try make(runID: AgentRunID()))),
    ]
    let client = HexGatewayClient(transport: MalformedEventGatewayTransport(records: records))
    _ = try await client.connect()
    let stream = try await client.eventRecords(
      for: runID, invocationID: GatewayTestValues.invocationID(171))
    var received: [AgentEventRecord] = []
    do {
      for try await envelope in stream { received.append(envelope.record) }
      Issue.record("Expected the wrong-owner compaction to fail.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .wrongRun)
    }
    #expect(received == Array(records.prefix(2)))
  }

  @Test
  func serviceRejectsWrongOwnerBeforeAdvancingReplay() async throws {
    let runID = GatewayTestValues.runID(172)
    let driver = ControllableGatewayRunDriver()
    let service = HexGatewayService(driver: driver)
    let handshake = try await service.handshake(GatewayTestValues.handshakeRequest())
    let start = try await service.startRun(
      GatewayTestValues.request(runID: runID), sessionID: handshake.sessionID)
    let invocationID = try #require(start.invocationID)
    await driver.waitUntilStarted(runID)
    let accepted = [
      GatewayTestValues.record(runID: runID, sequence: 1, event: .runStarted),
      GatewayTestValues.record(runID: runID, sequence: 2, event: .contextCompactionStarted),
    ]
    for record in accepted { await driver.yieldAndWait(record) }
    await driver.yieldAndWait(
      GatewayTestValues.record(
        runID: runID, sequence: 3, event: .contextCompacted(try make(runID: AgentRunID()))))
    await driver.waitUntilStopped(runID)
    let replay = try await service.eventRecords(
      after: GatewayEventCursor(runID: runID, invocationID: invocationID),
      sessionID: handshake.sessionID)
    var received: [AgentEventRecord] = []
    do {
      for try await envelope in replay { received.append(envelope.record) }
      Issue.record("Expected the rejected driver event to fail replay.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .wrongRun)
    }
    #expect(received == accepted)
  }

  @Test
  func malformedCompactionPayloadCannotCrossTheWire() throws {
    let codec = GatewayWireCodec(configuration: .standard)
    let event = AgentEvent.contextCompacted(try make(runID: AgentRunID()))
    let data = try codec.encode(event)
    let malformed = String(decoding: data, as: UTF8.self).replacingOccurrences(
      of: "Safe summary.", with: "")
    do {
      _ = try codec.decode(AgentEvent.self, from: Data(malformed.utf8))
      Issue.record("Expected the invalid summary to be rejected.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .malformedPayload)
    }
  }

  private func make(runID: AgentRunID) throws -> AgentContextCompaction {
    try AgentContextCompaction(
      ownerRunID: runID, sourceMessageIDs: [MessageID()], summaryText: "Safe summary.",
      providerID: ProviderID(rawValue: "test"), modelID: ModelID(rawValue: "test-model"),
      estimatedTokensBefore: 1000, estimatedTokensAfter: 100)
  }
}
