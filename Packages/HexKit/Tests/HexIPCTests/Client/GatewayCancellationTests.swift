import HexCore
import HexIPC
import Testing

@Suite("Gateway cancellation")
struct GatewayCancellationTests {
  @Test
  func cancellationEmitsDurableTerminalRecordAndIsIdempotent() async throws {
    let driver = ControllableGatewayRunDriver()
    let service = HexGatewayService(driver: driver)
    let transport = InProcessHexGatewayTransport(service: service)
    _ = try await transport.handshake(GatewayTestValues.handshakeRequest())

    let runID = GatewayTestValues.runID()
    let start = try await transport.startRun(GatewayTestValues.request(runID: runID))
    let invocationID = try #require(start.invocationID)
    await driver.waitUntilStarted(runID)
    await driver.setCancellationRecord(
      GatewayTestValues.record(runID: runID, sequence: 2, event: .runCancelled)
    )
    let stream = try await transport.eventRecords(
      after: GatewayEventCursor(runID: runID, invocationID: invocationID)
    )
    await driver.yieldAndWait(
      GatewayTestValues.record(runID: runID, sequence: 1, event: .runStarted)
    )

    let firstCancellation = try await transport.cancelRun(
      GatewayCancelRunRequest(runID: runID, invocationID: invocationID)
    )
    let records = try await GatewayTestValues.collect(stream)
    let repeatedCancellation = try await transport.cancelRun(
      GatewayCancelRunRequest(runID: runID, invocationID: invocationID)
    )

    #expect(firstCancellation.disposition == .requested)
    #expect(firstCancellation.invocationID == invocationID)
    #expect(records.map(\.sequence) == [1, 2])
    #expect(records.last?.event == .runCancelled)
    #expect(repeatedCancellation.disposition == .alreadyTerminal)
    #expect(repeatedCancellation.invocationID == invocationID)
  }

  @Test
  func cancellationAfterCompletionDoesNotCreateSecondTerminalEvent() async throws {
    let driver = ControllableGatewayRunDriver()
    let service = HexGatewayService(driver: driver)
    let transport = InProcessHexGatewayTransport(service: service)
    _ = try await transport.handshake(GatewayTestValues.handshakeRequest())

    let runID = GatewayTestValues.runID()
    let start = try await transport.startRun(GatewayTestValues.request(runID: runID))
    let invocationID = try #require(start.invocationID)
    await driver.waitUntilStarted(runID)
    await driver.yieldAndWait(
      GatewayTestValues.record(runID: runID, sequence: 1, event: .runStarted)
    )
    await driver.yieldAndWait(
      GatewayTestValues.record(runID: runID, sequence: 2, event: .runCompleted)
    )
    await driver.finish(runID)
    await driver.waitUntilStopped(runID)

    let response = try await transport.cancelRun(
      GatewayCancelRunRequest(runID: runID, invocationID: invocationID)
    )
    let replay = try await transport.eventRecords(
      after: GatewayEventCursor(runID: runID, invocationID: invocationID)
    )
    let records = try await GatewayTestValues.collect(replay)

    #expect(response.disposition == .alreadyTerminal)
    #expect(response.invocationID == invocationID)
    #expect(records.map(\.event) == [.runStarted, .runCompleted])
  }

  @Test
  func nonterminalUnwindOutputPreservesCancellingPhase() async throws {
    let driver = LaggingCancellationGatewayRunDriver()
    let service = HexGatewayService(driver: driver)
    let firstHandshake = try await service.handshake(GatewayTestValues.handshakeRequest(73))
    let runID = GatewayTestValues.runID(73)
    let start = try await service.startRun(
      GatewayTestValues.request(runID: runID),
      sessionID: firstHandshake.sessionID
    )
    let invocationID = try #require(start.invocationID)
    await driver.waitUntilStarted()

    _ = try await service.cancelRun(
      GatewayCancelRunRequest(runID: runID, invocationID: invocationID),
      sessionID: firstHandshake.sessionID
    )
    await driver.waitUntilLateRecord()

    let reconnect = try await service.handshake(GatewayTestValues.handshakeRequest(74))
    #expect(reconnect.activeRun?.phase == .cancelling)

    await driver.release()
    await driver.waitUntilStopped()
  }
}
