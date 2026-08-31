import HexCore
import HexIPC
import Testing

@Suite("Gateway slow consumers")
struct GatewaySlowConsumerTests {
  @Test
  func terminatesInsteadOfSilentlyDroppingARecord() async throws {
    let configuration = try #require(
      GatewayConfiguration(
        maximumWireBytes: 32_768,
        maximumRetainedRecordsPerRun: 2,
        subscriberBufferCapacity: 2
      )
    )
    let driver = ControllableGatewayRunDriver()
    let service = HexGatewayService(driver: driver, configuration: configuration)
    let handshake = try await service.handshake(GatewayTestValues.handshakeRequest())
    let runID = GatewayTestValues.runID()
    let request = GatewayTestValues.request(runID: runID)
    _ = try await service.startRun(request, sessionID: handshake.sessionID)
    await driver.waitUntilStarted(runID)
    let stream = try await service.eventRecords(
      after: GatewayEventCursor(runID: runID),
      sessionID: handshake.sessionID
    )

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
      _ = try await GatewayTestValues.collect(stream)
      Issue.record("Expected a bounded slow-consumer failure.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .consumerTooSlow)
    }
    await driver.finish(runID)
  }
}
