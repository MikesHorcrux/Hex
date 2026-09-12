import HexIPC
import Testing

@Suite("Gateway run admission")
struct GatewayRunAdmissionTests {
  @Test
  func makesDuplicateStartsIdempotentAndRejectsConflicts() async throws {
    let driver = ControllableGatewayRunDriver()
    let service = HexGatewayService(driver: driver)
    let transport = InProcessHexGatewayTransport(service: service)
    _ = try await transport.handshake(GatewayTestValues.handshakeRequest())

    let runID = GatewayTestValues.runID(1)
    let request = GatewayTestValues.request(runID: runID)
    let first = try await transport.startRun(request)
    let duplicate = try await transport.startRun(request)

    let invocationID = try #require(first.invocationID)
    #expect(first.disposition == .started(invocationID: invocationID))
    #expect(duplicate.disposition == .alreadyRunning(invocationID: invocationID))
    await driver.waitUntilStarted(runID)
    #expect(await driver.invocationCount(for: runID) == 1)

    do {
      _ = try await transport.startRun(
        GatewayTestValues.request(runID: runID, text: "different")
      )
      Issue.record("Expected a conflicting duplicate failure.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .conflictingRunRequest)
    }
  }

  @Test
  func admitsOnlyOneActiveRunAndRecognizesTerminalDuplicates() async throws {
    let driver = ControllableGatewayRunDriver()
    let service = HexGatewayService(driver: driver)
    let transport = InProcessHexGatewayTransport(service: service)
    _ = try await transport.handshake(GatewayTestValues.handshakeRequest())

    let firstRunID = GatewayTestValues.runID(1)
    let secondRunID = GatewayTestValues.runID(2)
    let firstRequest = GatewayTestValues.request(runID: firstRunID)
    let firstStart = try await transport.startRun(firstRequest)
    let firstInvocationID = try #require(firstStart.invocationID)
    await driver.waitUntilStarted(firstRunID)

    let busy = try await transport.startRun(GatewayTestValues.request(runID: secondRunID))
    #expect(busy.disposition == .busy(activeRunID: firstRunID))
    #expect(busy.invocationID == nil)

    await driver.yieldAndWait(
      GatewayTestValues.record(runID: firstRunID, sequence: 1, event: .runStarted)
    )
    await driver.yieldAndWait(
      GatewayTestValues.record(runID: firstRunID, sequence: 2, event: .runCompleted)
    )

    let terminalDuplicate = try await transport.startRun(firstRequest)
    #expect(
      terminalDuplicate.disposition == .alreadyTerminal(invocationID: firstInvocationID)
    )

    let secondStart = try await transport.startRun(
      GatewayTestValues.request(runID: secondRunID)
    )
    #expect(secondStart.invocationID != nil)
    guard case .started = secondStart.disposition else {
      await driver.finish(firstRunID)
      await driver.waitUntilStopped(firstRunID)
      return
    }
    await driver.waitUntilStarted(secondRunID)

    // Cleanup from the terminal run must not clear the newer run's active slot.
    await driver.finish(firstRunID)
    await driver.waitUntilStopped(firstRunID)
    let thirdRunID = GatewayTestValues.runID(3)
    let thirdStart = try await transport.startRun(
      GatewayTestValues.request(runID: thirdRunID)
    )
    #expect(thirdStart.disposition == .busy(activeRunID: secondRunID))

    await driver.yieldAndWait(
      GatewayTestValues.record(runID: secondRunID, sequence: 1, event: .runStarted)
    )
    await driver.yieldAndWait(
      GatewayTestValues.record(runID: secondRunID, sequence: 2, event: .runCompleted)
    )
    await driver.finish(secondRunID)
    await driver.waitUntilStopped(secondRunID)
  }
}
