import HexCore
import Testing
@testable import HexIPC

@Suite("Gateway run identity")
struct GatewayRunIdentityTests {
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
    #expect(newStart.disposition == .started)
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
      if probeStart.disposition == .started {
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
      after: GatewayEventCursor(runID: reusedRunID),
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
    #expect(replacementStart.disposition == .started)
    guard replacementStart.disposition == .started else {
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
