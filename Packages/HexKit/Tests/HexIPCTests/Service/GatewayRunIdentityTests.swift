import HexCore
import Testing

@testable import HexIPC

@Suite("Gateway run identity")
struct GatewayRunIdentityTests {
  @Test
  func publicIdentityRejectsStaleReplayAndCancellationAfterRunIDReuse() async throws {
    let configuration = try #require(
      GatewayConfiguration(
        maximumWireBytes: 32_768,
        maximumRetainedRecordsPerRun: 4,
        subscriberBufferCapacity: 4,
        maximumRememberedRuns: 1
      )
    )
    let driver = ABAGatewayRunDriver()
    let service = HexGatewayService(driver: driver, configuration: configuration)
    let transport = InProcessHexGatewayTransport(
      service: service,
      configuration: configuration
    )
    let client = HexGatewayClient(
      transport: transport,
      clientID: GatewayClientID(rawValue: GatewayTestValues.uuid(80))
    )
    _ = try await client.connect()
    let connectedLease = try #require(await client.connectedLease)
    let reusedRunID = GatewayTestValues.runID(80)
    let evictionRunID = GatewayTestValues.runID(81)

    let firstStart = try await client.startRun(
      GatewayTestValues.request(runID: reusedRunID)
    )
    let firstInvocationID = try #require(firstStart.invocationID)
    await driver.waitUntilStarted(1)
    let firstRecords = [
      GatewayTestValues.record(runID: reusedRunID, sequence: 1, event: .runStarted),
      GatewayTestValues.record(runID: reusedRunID, sequence: 2, event: .runCompleted),
    ]
    for record in firstRecords {
      await driver.yieldAndWait(record, from: 1)
    }
    await driver.finish(1)
    await driver.waitUntilStopped(1)
    let firstReplay = try await client.eventRecords(
      for: reusedRunID,
      invocationID: firstInvocationID
    )
    for record in try await GatewayTestValues.collect(firstReplay) {
      try await client.acknowledge(record, invocationID: firstInvocationID)
    }
    #expect(
      await client.acknowledgedCursor(
        for: reusedRunID,
        invocationID: firstInvocationID
      ).sequence == 2
    )
    let rememberedRetry = try await client.startRun(
      GatewayTestValues.request(runID: reusedRunID)
    )
    #expect(
      rememberedRetry.disposition == .alreadyTerminal(invocationID: firstInvocationID)
    )
    #expect(
      await client.acknowledgedCursor(
        for: reusedRunID,
        invocationID: firstInvocationID
      ).sequence == 2
    )

    _ = try await client.startRun(
      GatewayTestValues.request(runID: evictionRunID)
    )
    await driver.waitUntilStarted(2)
    await driver.yieldAndWait(
      GatewayTestValues.record(runID: evictionRunID, sequence: 1, event: .runStarted),
      from: 2
    )
    await driver.yieldAndWait(
      GatewayTestValues.record(runID: evictionRunID, sequence: 2, event: .runCompleted),
      from: 2
    )
    await driver.finish(2)
    await driver.waitUntilStopped(2)

    let replacementStart = try await client.startRun(
      GatewayTestValues.request(runID: reusedRunID)
    )
    let replacementInvocationID = try #require(replacementStart.invocationID)
    #expect(replacementInvocationID != firstInvocationID)
    #expect(
      await client.acknowledgedCursor(
        for: reusedRunID,
        invocationID: replacementInvocationID
      ).sequence == 0
    )
    await driver.waitUntilStarted(3)
    let replacementRecords = [
      GatewayTestValues.record(runID: reusedRunID, sequence: 1, event: .runStarted),
      GatewayTestValues.record(runID: reusedRunID, sequence: 2, event: .runCompleted),
    ]
    await driver.yieldAndWait(replacementRecords[0], from: 3)
    let observerHandshake = try await service.handshake(
      GatewayTestValues.handshakeRequest(82)
    )
    #expect(observerHandshake.activeRun?.runID == reusedRunID)
    #expect(observerHandshake.activeRun?.invocationID == replacementInvocationID)
    await service.disconnect(sessionID: observerHandshake.sessionID)

    do {
      _ = try await transport.eventRecords(
        after: GatewayEventCursor(
          runID: reusedRunID,
          invocationID: firstInvocationID,
          sequence: 2
        ),
        lease: connectedLease
      )
      Issue.record("Expected the old invocation cursor to be rejected.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .staleRunInvocation)
    }

    do {
      _ = try await transport.cancelRun(
        GatewayCancelRunRequest(
          runID: reusedRunID,
          invocationID: firstInvocationID
        ),
        lease: connectedLease
      )
      Issue.record("Expected stale cancellation to be rejected.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .staleRunInvocation)
    }
    #expect(await driver.isRunning(3))

    await driver.yieldAndWait(replacementRecords[1], from: 3)
    await driver.finish(3)
    await driver.waitUntilStopped(3)
    let replacementReplay = try await client.eventRecords(
      for: reusedRunID,
      invocationID: replacementInvocationID
    )
    #expect(try await GatewayTestValues.collect(replacementReplay) == replacementRecords)
  }

  @Test
  func staleCallbacksCannotMutateAnEvictedAndReusedRunID() async throws {
    let configuration = try #require(
      GatewayConfiguration(
        maximumWireBytes: 32_768,
        maximumRetainedRecordsPerRun: 4,
        subscriberBufferCapacity: 4,
        maximumRememberedRuns: 1
      )
    )
    let driver = ABAGatewayRunDriver()
    let service = HexGatewayService(driver: driver, configuration: configuration)
    let handshake = try await service.handshake(GatewayTestValues.handshakeRequest(90))
    let reusedRunID = GatewayTestValues.runID(90)
    let middleRunID = GatewayTestValues.runID(91)
    let probeRunID = GatewayTestValues.runID(92)

    _ = try await service.startRun(
      GatewayTestValues.request(runID: reusedRunID),
      sessionID: handshake.sessionID
    )
    await driver.waitUntilStarted(1)
    let oldStates = await service.runs
    let oldTask = try #require(oldStates[reusedRunID]?.task)
    await driver.yieldAndWait(
      GatewayTestValues.record(runID: reusedRunID, sequence: 1, event: .runStarted),
      from: 1
    )
    await driver.yieldAndWait(
      GatewayTestValues.record(runID: reusedRunID, sequence: 2, event: .runCompleted),
      from: 1
    )

    _ = try await service.startRun(
      GatewayTestValues.request(runID: middleRunID),
      sessionID: handshake.sessionID
    )
    await driver.waitUntilStarted(2)
    let middleStates = await service.runs
    let middleTask = try #require(middleStates[middleRunID]?.task)
    await driver.yieldAndWait(
      GatewayTestValues.record(runID: middleRunID, sequence: 1, event: .runStarted),
      from: 2
    )
    await driver.yieldAndWait(
      GatewayTestValues.record(runID: middleRunID, sequence: 2, event: .runCompleted),
      from: 2
    )
    await driver.finish(2)
    await middleTask.value

    let newStart = try await service.startRun(
      GatewayTestValues.request(runID: reusedRunID),
      sessionID: handshake.sessionID
    )
    let newInvocationID = try #require(newStart.invocationID)
    guard case .started = newStart.disposition else {
      Issue.record("Expected the reused identifier to start a new invocation.")
      return
    }
    await driver.waitUntilStarted(3)
    let newStates = await service.runs
    let newTask = try #require(newStates[reusedRunID]?.task)
    let newStartRecord = GatewayTestValues.record(
      runID: reusedRunID,
      sequence: 1,
      event: .runStarted
    )
    await driver.yieldAndWait(newStartRecord, from: 3)

    await driver.yieldAndWait(
      GatewayTestValues.record(
        runID: reusedRunID,
        sequence: 2,
        event: .messageAppended(
          GatewayTestValues.request(runID: reusedRunID).initialMessages[0]
        )
      ),
      from: 1
    )
    #expect(await driver.emissionFailureCount(for: 1) == 1)
    await driver.finish(1)
    await oldTask.value

    let probeStart = try await service.startRun(
      GatewayTestValues.request(runID: probeRunID),
      sessionID: handshake.sessionID
    )
    #expect(probeStart.disposition == .busy(activeRunID: reusedRunID))
    guard probeStart.disposition == .busy(activeRunID: reusedRunID) else {
      await driver.finish(3)
      if case .started = probeStart.disposition {
        await driver.waitUntilStarted(4)
        await driver.finish(4)
      }
      return
    }

    let newTerminalRecord = GatewayTestValues.record(
      runID: reusedRunID,
      sequence: 2,
      event: .runCompleted
    )
    await driver.yieldAndWait(newTerminalRecord, from: 3)
    await driver.finish(3)
    await newTask.value

    let replay = try await service.eventRecords(
      after: GatewayEventCursor(
        runID: reusedRunID,
        invocationID: newInvocationID
      ),
      sessionID: handshake.sessionID
    )
    #expect(try await GatewayTestValues.collect(replay) == [newStartRecord, newTerminalRecord])
  }

  @Test
  func invalidEmissionFailureReleasesOwnershipBeforeDefectiveDriverReturns() async throws {
    let driver = InvalidEmissionHangingGatewayRunDriver()
    let service = HexGatewayService(driver: driver)
    let handshake = try await service.handshake(GatewayTestValues.handshakeRequest(93))
    let failedRunID = GatewayTestValues.runID(93)
    let replacementRunID = GatewayTestValues.runID(94)
    let probeRunID = GatewayTestValues.runID(95)

    _ = try await service.startRun(
      GatewayTestValues.request(runID: failedRunID),
      sessionID: handshake.sessionID
    )
    let failedStates = await service.runs
    let failedTask = try #require(failedStates[failedRunID]?.task)
    await driver.waitUntilInvalidEmissionWasCaught()

    let replacementStart = try await service.startRun(
      GatewayTestValues.request(runID: replacementRunID),
      sessionID: handshake.sessionID
    )
    #expect(replacementStart.invocationID != nil)
    guard case .started = replacementStart.disposition else {
      await driver.releaseInvalidInvocation()
      await failedTask.value
      return
    }
    await driver.waitUntilReplacementStarted()
    let replacementStates = await service.runs
    let replacementTask = try #require(replacementStates[replacementRunID]?.task)

    await driver.releaseInvalidInvocation()
    await failedTask.value
    let probeStart = try await service.startRun(
      GatewayTestValues.request(runID: probeRunID),
      sessionID: handshake.sessionID
    )
    #expect(probeStart.disposition == .busy(activeRunID: replacementRunID))

    await driver.releaseReplacement()
    await replacementTask.value
  }
}
