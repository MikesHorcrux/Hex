import HexCore
import HexIPC
import Testing

@Suite("HexGatewayClient acknowledgements")
struct HexGatewayClientTests {
  @Test
  func advancesOnlyAfterAcknowledgementAndFiltersDuplicates() async throws {
    let runID = GatewayTestValues.runID()
    let firstRecord = GatewayTestValues.record(
      runID: runID,
      sequence: 1,
      event: .runStarted
    )
    let secondRecord = GatewayTestValues.record(
      runID: runID,
      sequence: 2,
      event: .runCompleted
    )
    let instanceID = GatewayInstanceID(rawValue: GatewayTestValues.uuid(40))
    let invocationID = GatewayTestValues.invocationID(40)
    let transport = FakeHexGatewayTransport(
      handshakeResponses: [
        response(instanceID: instanceID, sessionValue: 1),
        response(instanceID: instanceID, sessionValue: 2),
      ],
      recordsByRun: [runID: [firstRecord, secondRecord]]
    )
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()

    let stream = try await client.eventRecords(for: runID, invocationID: invocationID)
    let records = try await GatewayTestValues.collect(stream)
    #expect(records == [firstRecord, secondRecord])
    #expect(try await client.shouldApply(firstRecord, invocationID: invocationID))

    do {
      _ = try await client.shouldApply(secondRecord, invocationID: invocationID)
      Issue.record("Expected an unacknowledged sequence gap.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .invalidEventSequence)
    }

    try await client.acknowledge(firstRecord, invocationID: invocationID)
    #expect(try await !client.shouldApply(firstRecord, invocationID: invocationID))
    #expect(try await client.shouldApply(secondRecord, invocationID: invocationID))
    try await client.acknowledge(secondRecord, invocationID: invocationID)
    #expect(
      await client.acknowledgedCursor(for: runID, invocationID: invocationID).sequence == 2
    )

    _ = try await client.connect()
    _ = try await client.eventRecords(for: runID, invocationID: invocationID)
    #expect(await transport.requestedCursors().map(\.sequence) == [0, 2])
  }

  @Test
  func unacknowledgedRecordIsReplayedAtLeastOnce() async throws {
    let runID = GatewayTestValues.runID()
    let record = GatewayTestValues.record(
      runID: runID,
      sequence: 1,
      event: .runStarted
    )
    let instanceID = GatewayInstanceID(rawValue: GatewayTestValues.uuid(41))
    let invocationID = GatewayTestValues.invocationID(41)
    let transport = FakeHexGatewayTransport(
      handshakeResponses: [response(instanceID: instanceID, sessionValue: 1)],
      recordsByRun: [runID: [record]]
    )
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()

    let first = try await GatewayTestValues.collect(
      client.eventRecords(for: runID, invocationID: invocationID)
    )
    let second = try await GatewayTestValues.collect(
      client.eventRecords(for: runID, invocationID: invocationID)
    )

    #expect(first == [record])
    #expect(second == [record])
    #expect(await transport.requestedCursors().map(\.sequence) == [0, 0])
  }

  private func response(
    instanceID: GatewayInstanceID,
    sessionValue: UInt8
  ) -> GatewayHandshakeResponse {
    GatewayHandshakeResponse(
      sessionID: GatewaySessionID(rawValue: GatewayTestValues.uuid(sessionValue)),
      gatewayInstanceID: instanceID,
      selectedVersion: .current,
      activeRun: nil
    )
  }
}
