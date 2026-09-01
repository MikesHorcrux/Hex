import HexIPC
import Testing

@Suite("Gateway transport ordering")
struct GatewayTransportOrderingTests {
  @Test
  func delayedDisconnectCannotTearDownReplacementConnection() async throws {
    let transport = LateDisconnectGatewayTransport()
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()

    let staleDisconnect = Task { try await client.disconnect() }
    await transport.waitUntilDisconnectIsPending()
    _ = try await client.connect()
    await transport.releaseDisconnect()

    do {
      try await staleDisconnect.value
      Issue.record("Expected the old disconnect to be classified as superseded.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .supersededOperation)
    }

    let runID = GatewayTestValues.runID(181)
    let response = try await client.startRun(GatewayTestValues.request(runID: runID))
    #expect(response.runID == runID)
  }

  @Test
  func inProcessTransportIgnoresDisconnectFromSupersededLease() async throws {
    let service = HexGatewayService(driver: ImmediateGatewayRunDriver())
    let transport = InProcessHexGatewayTransport(service: service)
    let oldLease = GatewayTransportConnectionLease()
    let currentLease = GatewayTransportConnectionLease()
    _ = try await transport.handshake(
      GatewayTestValues.handshakeRequest(182),
      lease: oldLease
    )
    _ = try await transport.handshake(
      GatewayTestValues.handshakeRequest(183),
      lease: currentLease
    )

    await transport.disconnect(lease: oldLease)

    let runID = GatewayTestValues.runID(183)
    let response = try await transport.startRun(
      GatewayTestValues.request(runID: runID),
      lease: currentLease
    )
    #expect(response.runID == runID)
  }
}
