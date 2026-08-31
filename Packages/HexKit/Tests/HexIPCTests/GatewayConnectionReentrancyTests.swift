import HexCore
import HexIPC
import Testing

@Suite("Gateway connection reentrancy")
struct GatewayConnectionReentrancyTests {
  @Test
  func delayedOlderConnectCannotEraseCursorCommittedAfterNewerConnect() async throws {
    let transport = ReorderedHandshakeGatewayTransport()
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()
    let runID = GatewayTestValues.runID(201)
    let invocationID = GatewayTestValues.invocationID(201)
    let record = GatewayTestValues.record(
      runID: runID,
      sequence: 1,
      event: .runStarted
    )
    try await client.acknowledge(record, invocationID: invocationID)

    let delayedOlderConnect = Task {
      try await client.connect()
    }
    await transport.waitUntilDelayedHandshakeIsPending()

    _ = try await client.connect()
    try await client.acknowledge(record, invocationID: invocationID)
    #expect(
      await client.acknowledgedCursor(
        for: runID,
        invocationID: invocationID
      ).sequence == 1
    )

    await transport.releaseDelayedHandshake()
    await expectSuperseded(delayedOlderConnect)

    #expect(
      await client.acknowledgedCursor(
        for: runID,
        invocationID: invocationID
      ).sequence == 1
    )
  }

  @Test
  func cancellingOlderConnectCannotInvalidateNewerPendingConnect() async throws {
    let transport = HostileLifecycleGatewayTransport()
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()

    let olderConnect = Task { try await client.connect() }
    await transport.waitUntilHandshakeIsPending(2)
    let newerConnect = Task { try await client.connect() }
    await transport.waitUntilHandshakeIsPending(3)

    olderConnect.cancel()
    await Task.yield()
    await transport.resolveHandshake(3, instanceSeed: 204)
    let newerResult = try await newerConnect.value
    #expect(
      newerResult.response.gatewayInstanceID
        == GatewayInstanceID(rawValue: GatewayTestValues.uuid(204))
    )

    await transport.resolveHandshake(2, instanceSeed: 202)
    do {
      _ = try await olderConnect.value
      Issue.record("Expected cancellation from the older connection attempt.")
    } catch is CancellationError {
      // Expected.
    }
  }

  private func expectSuperseded(
    _ task: Task<GatewayConnectionResult, any Error>
  ) async {
    do {
      _ = try await task.value
      Issue.record("Expected a superseded connection attempt.")
    } catch let failure as GatewayFailure {
      #expect(
        failure
          == GatewayFailure(
            code: .supersededOperation,
            message: "The gateway client operation was superseded."
          )
      )
    } catch {
      Issue.record("Expected the fixed superseded failure, received: \(error)")
    }
  }
}
