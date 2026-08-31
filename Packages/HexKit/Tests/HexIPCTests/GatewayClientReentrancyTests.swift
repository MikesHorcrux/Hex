import HexCore
import HexIPC
import Testing

@Suite("Gateway client reentrancy")
struct GatewayClientReentrancyTests {
  @Test
  func cancelledStartCannotCommitDelayedResponseOrEraseCurrentCursor() async throws {
    let transport = ReorderingStartTransport()
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()
    let runID = GatewayTestValues.runID(99)
    let request = GatewayTestValues.request(runID: runID)

    let cancelledStart = Task {
      try await client.startRun(request)
    }
    await transport.waitUntilFirstStartIsPending()
    let currentStart = try await client.startRun(request)
    let currentInvocationID = try #require(currentStart.invocationID)
    let firstRecord = GatewayTestValues.record(
      runID: runID,
      sequence: 1,
      event: .runStarted
    )
    try await client.acknowledge(firstRecord, invocationID: currentInvocationID)

    cancelledStart.cancel()
    await transport.releaseFirstStart()
    do {
      _ = try await cancelledStart.value
      Issue.record("Expected the cancelled start to fail with cancellation.")
    } catch is CancellationError {
      // Expected.
    }

    #expect(
      await client.acknowledgedCursor(
        for: runID,
        invocationID: currentInvocationID
      ).sequence == 1
    )
  }

  @Test
  func cancellingOlderAttemptCannotInvalidateNewerPendingAttempt() async throws {
    let transport = TwoPendingStartTransport()
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()
    let runID = GatewayTestValues.runID(98)
    let request = GatewayTestValues.request(runID: runID)

    let olderStart = Task {
      try await client.startRun(request)
    }
    await transport.waitUntilPending(1)
    let newerStart = Task {
      try await client.startRun(request)
    }
    await transport.waitUntilPending(2)

    olderStart.cancel()
    await Task.yield()
    let newerInvocationID = GatewayTestValues.invocationID(98)
    await transport.release(2, invocationID: newerInvocationID)
    let newerResponse = try await newerStart.value
    #expect(newerResponse.disposition == .started(invocationID: newerInvocationID))

    let firstRecord = GatewayTestValues.record(
      runID: runID,
      sequence: 1,
      event: .runStarted
    )
    try await client.acknowledge(firstRecord, invocationID: newerInvocationID)

    await transport.release(1, invocationID: GatewayTestValues.invocationID(97))
    do {
      _ = try await olderStart.value
      Issue.record("Expected the cancelled older start to fail with cancellation.")
    } catch is CancellationError {
      // Expected.
    }

    #expect(
      await client.acknowledgedCursor(
        for: runID,
        invocationID: newerInvocationID
      ).sequence == 1
    )
  }

  @Test
  func delayedSupersededStartCannotEraseNewInvocationCursor() async throws {
    try await assertDelayedResponseIsSuperseded(
      .started(invocationID: GatewayTestValues.invocationID(91))
    )
  }

  @Test
  func delayedAlreadyRunningCannotEraseNewInvocationCursor() async throws {
    try await assertDelayedResponseIsSuperseded(
      .alreadyRunning(invocationID: GatewayTestValues.invocationID(91))
    )
  }

  @Test
  func delayedAlreadyTerminalCannotEraseNewInvocationCursor() async throws {
    try await assertDelayedResponseIsSuperseded(
      .alreadyTerminal(invocationID: GatewayTestValues.invocationID(91))
    )
  }

  @Test
  func delayedBusyCannotReturnAfterNewerStart() async throws {
    try await assertDelayedResponseIsSuperseded(
      .busy(activeRunID: GatewayTestValues.runID(90))
    )
  }

  @Test
  func delayedFailureIsRedactedWhenSuperseded() async throws {
    let transport = ReorderingStartTransport(
      delayedFailure: GatewayFailure(
        code: .transportUnavailable,
        message: "secret upstream failure details",
        isRetryable: true
      )
    )
    try await assertDelayedOperationIsSuperseded(transport: transport)
  }

  @Test
  func delayedMismatchedResponseIsRedactedWhenSuperseded() async throws {
    let transport = ReorderingStartTransport(
      delayedResponseRunID: GatewayTestValues.runID(89)
    )
    try await assertDelayedOperationIsSuperseded(transport: transport)
  }

  @Test
  func currentMismatchedResponseIsRejectedWithoutCursorMutation() async throws {
    let requestedRunID = GatewayTestValues.runID(87)
    let returnedInvocationID = GatewayTestValues.invocationID(87)
    let transport = MismatchedStartGatewayTransport(
      responseRunID: GatewayTestValues.runID(88),
      invocationID: returnedInvocationID
    )
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()

    do {
      _ = try await client.startRun(GatewayTestValues.request(runID: requestedRunID))
      Issue.record("Expected a mismatched start response to fail.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .wrongRun)
      #expect(failure.message == "The gateway returned a start response for a different run.")
      #expect(!failure.isRetryable)
    }

    #expect(
      await client.acknowledgedCursor(
        for: requestedRunID,
        invocationID: returnedInvocationID
      ).sequence == 0
    )
  }

  @Test
  func delayedValidProductionStartCannotEraseReusedInvocationCursor() async throws {
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
    let base = InProcessHexGatewayTransport(service: service, configuration: configuration)
    let delayedTransport = DelayedFirstStartTransport(base: base)
    let client = HexGatewayClient(transport: delayedTransport)
    _ = try await client.connect()
    let reusedRunID = GatewayTestValues.runID(100)
    let evictionRunID = GatewayTestValues.runID(101)

    let delayedStart = Task {
      try await client.startRun(GatewayTestValues.request(runID: reusedRunID))
    }
    await delayedTransport.waitUntilFirstResponseIsHeld()
    await driver.waitUntilStarted(1)
    await driver.yieldAndWait(
      GatewayTestValues.record(runID: reusedRunID, sequence: 1, event: .runStarted),
      from: 1
    )
    await driver.yieldAndWait(
      GatewayTestValues.record(runID: reusedRunID, sequence: 2, event: .runCompleted),
      from: 1
    )
    await driver.finish(1)
    await driver.waitUntilStopped(1)

    _ = try await base.startRun(GatewayTestValues.request(runID: evictionRunID))
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

    let replacementStart = try await base.startRun(
      GatewayTestValues.request(runID: reusedRunID)
    )
    let replacementInvocationID = try #require(replacementStart.invocationID)
    await driver.waitUntilStarted(3)
    let replacementStartRecord = GatewayTestValues.record(
      runID: reusedRunID,
      sequence: 1,
      event: .runStarted
    )
    await driver.yieldAndWait(replacementStartRecord, from: 3)

    let observedReplacement = try await client.startRun(
      GatewayTestValues.request(runID: reusedRunID)
    )
    #expect(
      observedReplacement.disposition
        == .alreadyRunning(invocationID: replacementInvocationID)
    )
    try await client.acknowledge(
      replacementStartRecord,
      invocationID: replacementInvocationID
    )

    await delayedTransport.releaseFirstResponse()
    await expectSuperseded(delayedStart)

    #expect(
      await client.acknowledgedCursor(
        for: reusedRunID,
        invocationID: replacementInvocationID
      ).sequence == 1
    )

    await driver.yieldAndWait(
      GatewayTestValues.record(runID: reusedRunID, sequence: 2, event: .runCompleted),
      from: 3
    )
    await driver.finish(3)
    await driver.waitUntilStopped(3)
  }

  private func assertDelayedResponseIsSuperseded(
    _ disposition: GatewayStartRunDisposition
  ) async throws {
    try await assertDelayedOperationIsSuperseded(
      transport: ReorderingStartTransport(delayedDisposition: disposition)
    )
  }

  private func assertDelayedOperationIsSuperseded(
    transport: ReorderingStartTransport
  ) async throws {
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()
    let runID = GatewayTestValues.runID(91)
    let request = GatewayTestValues.request(runID: runID)

    let delayedStart = Task {
      try await client.startRun(request)
    }
    await transport.waitUntilFirstStartIsPending()

    let currentStart = try await client.startRun(request)
    let currentInvocationID = try #require(currentStart.invocationID)
    let firstRecord = GatewayTestValues.record(
      runID: runID,
      sequence: 1,
      event: .runStarted
    )
    try await client.acknowledge(firstRecord, invocationID: currentInvocationID)

    await transport.releaseFirstStart()
    await expectSuperseded(delayedStart)

    #expect(currentStart.disposition == .started(invocationID: currentInvocationID))
    #expect(
      await client.acknowledgedCursor(
        for: runID,
        invocationID: currentInvocationID
      ).sequence == 1
    )
  }

  private func expectSuperseded(
    _ task: Task<GatewayStartRunResponse, any Error>
  ) async {
    do {
      _ = try await task.value
      Issue.record("Expected a superseded start failure.")
    } catch let failure as GatewayFailure {
      #expect(
        failure
          == GatewayFailure(
            code: .supersededOperation,
            message: "The start operation was superseded by a newer attempt.",
            isRetryable: false
          )
      )
    } catch {
      Issue.record("Expected the fixed superseded start failure, received: \(error)")
    }
  }
}
