import HexCore
import Testing

@testable import HexIPC

@Suite("Gateway client event lifecycle regressions")
struct GatewayClientEventLifecycleRegressionTests {
  @Test
  func postTerminalRecordNeverCrossesTheClientBoundary() async throws {
    let runID = GatewayTestValues.runID(221)
    let request = GatewayTestValues.request(runID: runID)
    let transport = MalformedEventGatewayTransport(
      records: [
        GatewayTestValues.record(runID: runID, sequence: 1, event: .runStarted),
        GatewayTestValues.record(runID: runID, sequence: 2, event: .runCompleted),
        GatewayTestValues.record(
          runID: runID,
          sequence: 3,
          event: .messageAppended(request.initialMessages[0])
        ),
      ]
    )
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()

    await expectStreamFailure(
      client: client,
      runID: runID,
      invocationID: GatewayTestValues.invocationID(221),
      code: .eventAfterTerminal
    )
  }

  @Test
  func postTerminalRecordAfterReconnectNeverCrossesTheClientBoundary() async throws {
    let runID = GatewayTestValues.runID(237)
    let invocationID = GatewayTestValues.invocationID(237)
    let transport = MalformedEventGatewayTransport(
      records: [
        GatewayTestValues.record(
          runID: runID,
          sequence: 3,
          event: .messageAppended(GatewayTestValues.request(runID: runID).initialMessages[0])
        )
      ]
    )
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()
    try await client.acknowledge(
      GatewayTestValues.record(runID: runID, sequence: 1, event: .runStarted),
      invocationID: invocationID
    )
    try await client.acknowledge(
      GatewayTestValues.record(runID: runID, sequence: 2, event: .runCompleted),
      invocationID: invocationID
    )

    await expectStreamFailure(
      client: client,
      runID: runID,
      invocationID: invocationID,
      code: .eventAfterTerminal
    )
  }

  @Test
  func fullyAcknowledgedTerminalReplayMayCompleteWithoutADuplicateTerminal() async throws {
    let runID = GatewayTestValues.runID(238)
    let invocationID = GatewayTestValues.invocationID(238)
    let client = HexGatewayClient(transport: MalformedEventGatewayTransport(records: []))
    _ = try await client.connect()
    try await client.acknowledge(
      GatewayTestValues.record(runID: runID, sequence: 1, event: .runStarted),
      invocationID: invocationID
    )
    try await client.acknowledge(
      GatewayTestValues.record(runID: runID, sequence: 2, event: .runCompleted),
      invocationID: invocationID
    )

    let replay = try await client.eventRecords(for: runID, invocationID: invocationID)
    #expect(try await GatewayTestValues.collect(replay).isEmpty)
  }

  @Test
  func streamEndingWithoutTerminalNeverCompletesSuccessfully() async throws {
    let runID = GatewayTestValues.runID(222)
    let transport = MalformedEventGatewayTransport(
      records: [GatewayTestValues.record(runID: runID, sequence: 1, event: .runStarted)]
    )
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()

    await expectStreamFailure(
      client: client,
      runID: runID,
      invocationID: GatewayTestValues.invocationID(222),
      code: .producerEndedWithoutTerminalEvent
    )
  }

  private func expectStreamFailure(
    client: HexGatewayClient,
    runID: AgentRunID,
    invocationID: GatewayRunInvocationID,
    code: GatewayFailureCode
  ) async {
    do {
      let stream = try await client.eventRecords(for: runID, invocationID: invocationID)
      _ = try await GatewayTestValues.collect(stream)
      Issue.record("Expected the hostile event stream to fail with \(code).")
    } catch let failure as GatewayFailure {
      #expect(failure.code == code)
    } catch {
      Issue.record("Expected a gateway failure, received: \(error)")
    }
  }
}
