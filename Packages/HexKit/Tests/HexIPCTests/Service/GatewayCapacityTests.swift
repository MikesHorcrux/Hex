import HexCore
import HexIPC
import Testing

@Suite("Gateway bounded ownership")
struct GatewayCapacityTests {
  @Test
  func boundsActiveSessionsAndRecoversCapacityOnDisconnect() async throws {
    let configuration = try #require(
      GatewayConfiguration(
        maximumWireBytes: 32_768,
        maximumRetainedRecordsPerRun: 2,
        subscriberBufferCapacity: 2,
        maximumSessions: 2,
        maximumRememberedRuns: 2
      )
    )
    let service = HexGatewayService(
      driver: ControllableGatewayRunDriver(),
      configuration: configuration
    )
    let first = try await service.handshake(GatewayTestValues.handshakeRequest(1))
    _ = try await service.handshake(GatewayTestValues.handshakeRequest(2))

    do {
      _ = try await service.handshake(GatewayTestValues.handshakeRequest(3))
      Issue.record("Expected the session capacity to fail closed.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .capacityExceeded)
    }

    await service.disconnect(sessionID: first.sessionID)
    _ = try await service.handshake(GatewayTestValues.handshakeRequest(3))
  }

  @Test
  func evictsOldestCompletedRunAtConfiguredBound() async throws {
    let configuration = try #require(
      GatewayConfiguration(
        maximumWireBytes: 32_768,
        maximumRetainedRecordsPerRun: 2,
        subscriberBufferCapacity: 2,
        maximumSessions: 2,
        maximumRememberedRuns: 2
      )
    )
    let driver = ControllableGatewayRunDriver()
    let service = HexGatewayService(driver: driver, configuration: configuration)
    let transport = InProcessHexGatewayTransport(
      service: service,
      configuration: configuration
    )
    _ = try await transport.handshake(GatewayTestValues.handshakeRequest())

    let firstRunID = GatewayTestValues.runID(1)
    let secondRunID = GatewayTestValues.runID(2)
    let thirdRunID = GatewayTestValues.runID(3)
    let firstInvocationID = try await complete(
      firstRunID,
      driver: driver,
      transport: transport
    )
    let secondInvocationID = try await complete(
      secondRunID,
      driver: driver,
      transport: transport
    )
    let thirdInvocationID = try await complete(
      thirdRunID,
      driver: driver,
      transport: transport
    )

    do {
      _ = try await transport.eventRecords(
        after: GatewayEventCursor(
          runID: firstRunID,
          invocationID: firstInvocationID
        )
      )
      Issue.record("Expected the oldest completed run to be evicted.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .runNotFound)
    }

    let secondReplay = try await transport.eventRecords(
      after: GatewayEventCursor(runID: secondRunID, invocationID: secondInvocationID)
    )
    let thirdReplay = try await transport.eventRecords(
      after: GatewayEventCursor(runID: thirdRunID, invocationID: thirdInvocationID)
    )
    #expect(try await GatewayTestValues.collect(secondReplay).map(\.sequence) == [1, 2])
    #expect(try await GatewayTestValues.collect(thirdReplay).map(\.sequence) == [1, 2])
  }

  @Test
  func boundsLiveSubscribersPerRun() async throws {
    let configuration = try #require(
      GatewayConfiguration(
        maximumWireBytes: 32_768,
        maximumRetainedRecordsPerRun: 1,
        subscriberBufferCapacity: 1,
        maximumSubscribersPerRun: 1
      )
    )
    let driver = ControllableGatewayRunDriver()
    let service = HexGatewayService(driver: driver, configuration: configuration)
    let handshake = try await service.handshake(GatewayTestValues.handshakeRequest())
    let runID = GatewayTestValues.runID()
    let start = try await service.startRun(
      GatewayTestValues.request(runID: runID),
      sessionID: handshake.sessionID
    )
    let invocationID = try #require(start.invocationID)
    await driver.waitUntilStarted(runID)

    let firstStream = try await service.eventRecords(
      after: GatewayEventCursor(runID: runID, invocationID: invocationID),
      sessionID: handshake.sessionID
    )
    defer { _ = firstStream }
    let rejectedStream = try await service.eventRecords(
      after: GatewayEventCursor(runID: runID, invocationID: invocationID),
      sessionID: handshake.sessionID
    )
    do {
      _ = try await GatewayTestValues.collect(rejectedStream)
      Issue.record("Expected the subscriber capacity to fail closed.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .capacityExceeded)
    }

    await service.disconnect(sessionID: handshake.sessionID)
    await driver.finish(runID)
  }

  private func complete(
    _ runID: AgentRunID,
    driver: ControllableGatewayRunDriver,
    transport: InProcessHexGatewayTransport
  ) async throws -> GatewayRunInvocationID {
    var response = try await transport.startRun(GatewayTestValues.request(runID: runID))
    while case .busy = response.disposition {
      await Task.yield()
      response = try await transport.startRun(GatewayTestValues.request(runID: runID))
    }
    guard case .started(let invocationID) = response.disposition else {
      Issue.record("Expected a newly admitted run invocation.")
      throw GatewayFailure(
        code: .runDriverFailed,
        message: "The test run was not admitted."
      )
    }
    await driver.waitUntilStarted(runID)
    await driver.yield(
      GatewayTestValues.record(runID: runID, sequence: 1, event: .runStarted)
    )
    await driver.yield(
      GatewayTestValues.record(runID: runID, sequence: 2, event: .runCompleted)
    )
    await driver.finish(runID)
    await driver.waitUntilStopped(runID)
    return invocationID
  }
}
