import HexCore
import HexIPC
import Testing

@Suite("Gateway cursor boundaries")
struct GatewayCursorBoundaryTests {
  @Test
  func rejectsCursorAheadOfHighWater() async throws {
    let driver = ControllableGatewayRunDriver()
    let service = HexGatewayService(driver: driver)
    let transport = InProcessHexGatewayTransport(service: service)
    _ = try await transport.handshake(GatewayTestValues.handshakeRequest())
    let runID = GatewayTestValues.runID()
    let start = try await transport.startRun(GatewayTestValues.request(runID: runID))
    let invocationID = try #require(start.invocationID)
    await driver.waitUntilStarted(runID)

    do {
      _ = try await transport.eventRecords(
        after: GatewayEventCursor(
          runID: runID,
          invocationID: invocationID,
          sequence: 1
        )
      )
      Issue.record("Expected an invalid cursor failure.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .invalidCursor)
    }
  }

  @Test
  func reportsReplayUnavailableWhenCursorPredatesBoundedHistory() async throws {
    let configuration = try #require(
      GatewayConfiguration(
        maximumWireBytes: 32_768,
        maximumRetainedRecordsPerRun: 2,
        subscriberBufferCapacity: 2
      )
    )
    let driver = ControllableGatewayRunDriver()
    let service = HexGatewayService(driver: driver, configuration: configuration)
    let transport = InProcessHexGatewayTransport(
      service: service,
      configuration: configuration
    )
    _ = try await transport.handshake(GatewayTestValues.handshakeRequest())
    let runID = GatewayTestValues.runID()
    let request = GatewayTestValues.request(runID: runID)
    let start = try await transport.startRun(request)
    let invocationID = try #require(start.invocationID)
    await driver.waitUntilStarted(runID)
    await driver.yieldAndWait(
      GatewayTestValues.record(runID: runID, sequence: 1, event: .runStarted)
    )
    await driver.yieldAndWait(
      GatewayTestValues.record(
        runID: runID,
        sequence: 2,
        event: .messageAppended(request.initialMessages[0])
      )
    )
    await driver.yieldAndWait(
      GatewayTestValues.record(runID: runID, sequence: 3, event: .runCompleted)
    )

    do {
      _ = try await transport.eventRecords(
        after: GatewayEventCursor(runID: runID, invocationID: invocationID)
      )
      Issue.record("Expected replay-window failure.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .replayUnavailable)
    }
    await driver.finish(runID)
  }
}
