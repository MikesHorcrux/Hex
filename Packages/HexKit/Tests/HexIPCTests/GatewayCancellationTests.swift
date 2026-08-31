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
    _ = try await transport.startRun(GatewayTestValues.request(runID: runID))
    await driver.waitUntilStarted(runID)
    await driver.setCancellationRecord(
      GatewayTestValues.record(runID: runID, sequence: 2, event: .runCancelled)
    )
    let stream = try await transport.eventRecords(after: GatewayEventCursor(runID: runID))
    await driver.yieldAndWait(
      GatewayTestValues.record(runID: runID, sequence: 1, event: .runStarted)
    )

    let firstCancellation = try await transport.cancelRun(GatewayCancelRunRequest(runID: runID))
    let records = try await GatewayTestValues.collect(stream)
    let repeatedCancellation = try await transport.cancelRun(
      GatewayCancelRunRequest(runID: runID)
    )

    #expect(firstCancellation.disposition == .requested)
    #expect(records.map(\.sequence) == [1, 2])
    #expect(records.last?.event == .runCancelled)
    #expect(repeatedCancellation.disposition == .alreadyTerminal)
  }

  @Test
  func cancellationAfterCompletionDoesNotCreateSecondTerminalEvent() async throws {
    let driver = ControllableGatewayRunDriver()
    let service = HexGatewayService(driver: driver)
    let transport = InProcessHexGatewayTransport(service: service)
    _ = try await transport.handshake(GatewayTestValues.handshakeRequest())

    let runID = GatewayTestValues.runID()
    _ = try await transport.startRun(GatewayTestValues.request(runID: runID))
    await driver.waitUntilStarted(runID)
    await driver.yieldAndWait(
      GatewayTestValues.record(runID: runID, sequence: 1, event: .runStarted)
    )
    await driver.yieldAndWait(
      GatewayTestValues.record(runID: runID, sequence: 2, event: .runCompleted)
    )
    await driver.finish(runID)
    await driver.waitUntilStopped(runID)

    let response = try await transport.cancelRun(GatewayCancelRunRequest(runID: runID))
    let replay = try await transport.eventRecords(after: GatewayEventCursor(runID: runID))
    let records = try await GatewayTestValues.collect(replay)

    #expect(response.disposition == .alreadyTerminal)
    #expect(records.map(\.event) == [.runStarted, .runCompleted])
  }
}
