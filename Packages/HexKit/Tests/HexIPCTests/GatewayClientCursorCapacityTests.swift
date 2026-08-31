import HexCore
import Testing
@testable import HexIPC

@Suite("Gateway client cursor capacity")
struct GatewayClientCursorCapacityTests {
  @Test
  func honestEvictedRunsDoNotGrowClientCursorStateWithoutBound() async throws {
    let configuration = try #require(
      GatewayConfiguration(
        maximumWireBytes: 32_768,
        maximumRetainedRecordsPerRun: 2,
        subscriberBufferCapacity: 2,
        maximumRememberedRuns: 1
      )
    )
    let service = HexGatewayService(
      driver: ImmediateGatewayRunDriver(),
      configuration: configuration
    )
    let transport = InProcessHexGatewayTransport(
      service: service,
      configuration: configuration
    )
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()

    for seed in UInt8(1)...UInt8(20) {
      let runID = GatewayTestValues.runID(seed)
      let response = try await client.startRun(GatewayTestValues.request(runID: runID))
      let invocationID = try #require(response.invocationID)
      let stream = try await client.eventRecords(for: runID, invocationID: invocationID)
      let records = try await GatewayTestValues.collect(stream)
      #expect(records.count == 2)
      for record in records {
        try await client.acknowledge(record, invocationID: invocationID)
      }
    }

    #expect(
      await client.acknowledgedSequences.count
        <= GatewayConfiguration.standard.maximumRememberedRuns
    )
  }

  @Test
  func configuredCapacityEvictsToSafeReplayFromZero() async throws {
    let configuration = try #require(
      GatewayConfiguration(
        maximumWireBytes: 32_768,
        maximumRetainedRecordsPerRun: 2,
        subscriberBufferCapacity: 2,
        maximumRememberedRuns: 1
      )
    )
    let client = HexGatewayClient(
      transport: FakeHexGatewayTransport(handshakeResponses: []),
      configuration: configuration
    )
    let firstRunID = GatewayTestValues.runID(30)
    let firstInvocationID = GatewayTestValues.invocationID(30)
    let firstRecord = GatewayTestValues.record(
      runID: firstRunID,
      sequence: 1,
      event: .runStarted
    )
    try await client.acknowledge(firstRecord, invocationID: firstInvocationID)
    try await client.acknowledge(
      GatewayTestValues.record(
        runID: GatewayTestValues.runID(31),
        sequence: 1,
        event: .runStarted
      ),
      invocationID: GatewayTestValues.invocationID(31)
    )

    #expect(await client.acknowledgedSequences.count == 1)
    #expect(
      await client.acknowledgedCursor(
        for: firstRunID,
        invocationID: firstInvocationID
      ).sequence == 0
    )
    #expect(try await client.shouldApply(firstRecord, invocationID: firstInvocationID))
  }
}
