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

    #expect(first.disposition == .started)
    #expect(duplicate.disposition == .alreadyRunning)
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
    _ = try await transport.startRun(firstRequest)
    await driver.waitUntilStarted(firstRunID)

    let busy = try await transport.startRun(GatewayTestValues.request(runID: secondRunID))
    #expect(busy.disposition == .busy(activeRunID: firstRunID))

    await driver.yieldAndWait(
      GatewayTestValues.record(runID: firstRunID, sequence: 1, event: .runStarted)
    )
    await driver.yieldAndWait(
      GatewayTestValues.record(runID: firstRunID, sequence: 2, event: .runCompleted)
    )

    let terminalDuplicate = try await transport.startRun(firstRequest)
    #expect(terminalDuplicate.disposition == .alreadyTerminal)
    await driver.finish(firstRunID)
  }
}
