import HexCore
import HexIPC
import Testing

@Suite("Gateway replay and reconnect")
struct GatewayReplayTests {
  @Test
  func disconnectBeforeFirstRecordStillAllowsFullReconnectReplay() async throws {
    let driver = ControllableGatewayRunDriver()
    let service = HexGatewayService(driver: driver)
    let firstTransport = InProcessHexGatewayTransport(service: service)
    _ = try await firstTransport.handshake(GatewayTestValues.handshakeRequest(1))
    let runID = GatewayTestValues.runID()
    _ = try await firstTransport.startRun(GatewayTestValues.request(runID: runID))
    await driver.waitUntilStarted(runID)
    let abandonedStream = try await firstTransport.eventRecords(
      after: GatewayEventCursor(runID: runID)
    )

    await firstTransport.disconnect()
    do {
      _ = try await GatewayTestValues.collect(abandonedStream)
      Issue.record("Expected the abandoned stream to report disconnection.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .disconnected)
    }

    let records = [
      GatewayTestValues.record(runID: runID, sequence: 1, event: .runStarted),
      GatewayTestValues.record(runID: runID, sequence: 2, event: .runCompleted),
    ]
    for record in records {
      await driver.yieldAndWait(record)
    }
    await driver.finish(runID)
    await driver.waitUntilStopped(runID)

    let secondTransport = InProcessHexGatewayTransport(service: service)
    _ = try await secondTransport.handshake(GatewayTestValues.handshakeRequest(2))
    let replay = try await secondTransport.eventRecords(
      after: GatewayEventCursor(runID: runID)
    )
    #expect(try await GatewayTestValues.collect(replay) == records)
    await driver.finish(runID)
  }

  @Test
  func disconnectKeepsRunAliveAndReconnectHasNoGap() async throws {
    let driver = ControllableGatewayRunDriver()
    let service = HexGatewayService(driver: driver)
    let firstTransport = InProcessHexGatewayTransport(service: service)
    _ = try await firstTransport.handshake(GatewayTestValues.handshakeRequest(1))

    let runID = GatewayTestValues.runID()
    let request = GatewayTestValues.request(runID: runID)
    let firstRecord = GatewayTestValues.record(
      runID: runID,
      sequence: 1,
      event: .runStarted
    )
    let secondRecord = GatewayTestValues.record(
      runID: runID,
      sequence: 2,
      event: .messageAppended(request.initialMessages[0])
    )
    let thirdRecord = GatewayTestValues.record(
      runID: runID,
      sequence: 3,
      event: .runCompleted
    )

    _ = try await firstTransport.startRun(request)
    await driver.waitUntilStarted(runID)
    let initialStream = try await firstTransport.eventRecords(
      after: GatewayEventCursor(runID: runID)
    )
    var iterator = initialStream.makeAsyncIterator()
    await driver.yield(firstRecord)
    #expect(try await iterator.next() == firstRecord)

    await firstTransport.disconnect()
    do {
      _ = try await iterator.next()
      Issue.record("Expected the disconnected stream to terminate with an error.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .disconnected)
    }

    await driver.yield(secondRecord)

    let secondTransport = InProcessHexGatewayTransport(service: service)
    _ = try await secondTransport.handshake(GatewayTestValues.handshakeRequest(2))
    let reconnectTask = Task {
      let stream = try await secondTransport.eventRecords(
        after: GatewayEventCursor(runID: runID, sequence: 1)
      )
      return try await GatewayTestValues.collect(stream)
    }
    await Task.yield()
    await driver.yield(thirdRecord)
    await driver.finish(runID)

    let reconnectedRecords = try await reconnectTask.value
    #expect(reconnectedRecords == [secondRecord, thirdRecord])
    #expect(await driver.invocationCount(for: runID) == 1)
  }

  @Test
  func cursorZeroReplaysTheWholeRetainedRun() async throws {
    let driver = ControllableGatewayRunDriver()
    let service = HexGatewayService(driver: driver)
    let transport = InProcessHexGatewayTransport(service: service)
    _ = try await transport.handshake(GatewayTestValues.handshakeRequest())
    let runID = GatewayTestValues.runID()
    _ = try await transport.startRun(GatewayTestValues.request(runID: runID))
    await driver.waitUntilStarted(runID)
    let records = [
      GatewayTestValues.record(runID: runID, sequence: 1, event: .runStarted),
      GatewayTestValues.record(runID: runID, sequence: 2, event: .runCompleted),
    ]
    for record in records {
      await driver.yieldAndWait(record)
    }
    await driver.finish(runID)
    await driver.waitUntilStopped(runID)

    let stream = try await transport.eventRecords(after: GatewayEventCursor(runID: runID))
    #expect(try await GatewayTestValues.collect(stream) == records)
  }
}
