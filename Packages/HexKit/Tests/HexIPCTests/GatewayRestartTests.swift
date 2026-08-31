import HexIPC
import Testing

@Suite("Gateway restart detection")
struct GatewayRestartTests {
  @Test
  func clientClearsAcknowledgementsWhenInstanceChanges() async throws {
    let runID = GatewayTestValues.runID()
    let record = GatewayTestValues.record(
      runID: runID,
      sequence: 1,
      event: .runStarted
    )
    let firstInstanceID = GatewayInstanceID(rawValue: GatewayTestValues.uuid(21))
    let secondInstanceID = GatewayInstanceID(rawValue: GatewayTestValues.uuid(22))
    let transport = FakeHexGatewayTransport(
      handshakeResponses: [
        response(instanceID: firstInstanceID, sessionValue: 1),
        response(instanceID: secondInstanceID, sessionValue: 2),
      ],
      recordsByRun: [runID: [record]]
    )
    let client = HexGatewayClient(transport: transport)

    let initialConnection = try await client.connect()
    try await client.acknowledge(record)
    #expect(await client.acknowledgedCursor(for: runID).sequence == 1)

    let restartedConnection = try await client.connect()
    #expect(!initialConnection.didDetectGatewayRestart)
    #expect(restartedConnection.didDetectGatewayRestart)
    #expect(await client.acknowledgedCursor(for: runID).sequence == 0)
  }

  @Test
  func newServiceNeverPretendsOldRunIsReplayable() async throws {
    let oldInstanceID = GatewayInstanceID(rawValue: GatewayTestValues.uuid(31))
    let newInstanceID = GatewayInstanceID(rawValue: GatewayTestValues.uuid(32))
    let oldService = HexGatewayService(
      driver: ControllableGatewayRunDriver(),
      gatewayInstanceID: oldInstanceID
    )
    let newService = HexGatewayService(
      driver: ControllableGatewayRunDriver(),
      gatewayInstanceID: newInstanceID
    )
    let oldHandshake = try await oldService.handshake(GatewayTestValues.handshakeRequest(1))
    let newHandshake = try await newService.handshake(GatewayTestValues.handshakeRequest(2))

    #expect(oldHandshake.gatewayInstanceID != newHandshake.gatewayInstanceID)
    do {
      _ = try await newService.eventRecords(
        after: GatewayEventCursor(runID: GatewayTestValues.runID(), sequence: 1),
        sessionID: newHandshake.sessionID
      )
      Issue.record("Expected an old run to be unavailable after service replacement.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .runNotFound)
    }
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
