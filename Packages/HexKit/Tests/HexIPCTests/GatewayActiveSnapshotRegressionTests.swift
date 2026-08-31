import HexIPC
import Testing

@Suite("Gateway active snapshot regression")
struct GatewayActiveSnapshotRegressionTests {
  @Test
  func sameInstanceSnapshotCannotRegressBelowAcknowledgedCursor() async throws {
    let transport = RegressingSnapshotGatewayTransport()
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()
    let runID = transport.runID
    let invocationID = transport.invocationID
    let stream = try await client.eventRecords(for: runID, invocationID: invocationID)
    for try await envelope in stream {
      try await client.acknowledge(envelope)
    }
    #expect(
      await client.acknowledgedCursor(for: runID, invocationID: invocationID).sequence == 2
    )

    do {
      _ = try await client.connect()
      Issue.record("Expected the regressed active snapshot to be rejected.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .invalidCursor)
    }
  }
}
