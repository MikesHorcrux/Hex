import HexIPC
import Testing

@Suite("Gateway sessions")
struct GatewaySessionTests {
  @Test
  func rejectsCommandsBeforeHandshakeAndAfterSessionInvalidation() async throws {
    let driver = ControllableGatewayRunDriver()
    let service = HexGatewayService(driver: driver)
    let transport = InProcessHexGatewayTransport(service: service)
    let request = GatewayTestValues.request(runID: GatewayTestValues.runID())

    do {
      _ = try await transport.startRun(request)
      Issue.record("Expected an unconnected transport failure.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .notConnected)
    }

    let handshake = try await service.handshake(GatewayTestValues.handshakeRequest())
    await service.disconnect(sessionID: handshake.sessionID)

    do {
      _ = try await service.startRun(request, sessionID: handshake.sessionID)
      Issue.record("Expected a stale session failure.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .staleSession)
    }
  }
}
