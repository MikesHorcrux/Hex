import HexCore
import HexIPC
import Testing

@Suite("Gateway event ordering")
struct GatewayEventOrderingTests {
  @Test
  func streamsExactlyIncreasingRecordsThroughTerminal() async throws {
    let runID = GatewayTestValues.runID()
    let records = [
      GatewayTestValues.record(runID: runID, sequence: 1, event: .runStarted),
      GatewayTestValues.record(
        runID: runID,
        sequence: 2,
        event: .messageAppended(
          GatewayTestValues.request(runID: runID).initialMessages[0]
        )
      ),
      GatewayTestValues.record(runID: runID, sequence: 3, event: .runCompleted),
    ]

    let replay = try await replayAfterDriving(records, runID: runID)
    #expect(replay == records)
  }

  @Test
  func rejectsDuplicateAndGapSequences() async {
    let runID = GatewayTestValues.runID()
    await expectFailure(
      records: [
        GatewayTestValues.record(runID: runID, sequence: 1, event: .runStarted),
        GatewayTestValues.record(runID: runID, sequence: 1, event: .runCompleted),
      ],
      runID: runID,
      code: .invalidEventSequence
    )
    await expectFailure(
      records: [
        GatewayTestValues.record(runID: runID, sequence: 1, event: .runStarted),
        GatewayTestValues.record(runID: runID, sequence: 3, event: .runCompleted),
      ],
      runID: runID,
      code: .invalidEventSequence
    )
  }

  @Test
  func rejectsWrongRunAndUnsupportedSchema() async {
    let runID = GatewayTestValues.runID(1)
    let otherRunID = GatewayTestValues.runID(2)
    await expectFailure(
      records: [
        GatewayTestValues.record(runID: otherRunID, sequence: 1, event: .runStarted)
      ],
      runID: runID,
      code: .wrongRun
    )
    await expectFailure(
      records: [
        GatewayTestValues.record(
          runID: runID,
          sequence: 1,
          schemaVersion: 2,
          event: .runStarted
        )
      ],
      runID: runID,
      code: .unsupportedEventSchema
    )
  }

  @Test
  func rejectsRecordsAfterTerminal() async {
    let runID = GatewayTestValues.runID()
    await expectFailure(
      records: [
        GatewayTestValues.record(runID: runID, sequence: 1, event: .runStarted),
        GatewayTestValues.record(runID: runID, sequence: 2, event: .runCompleted),
        GatewayTestValues.record(
          runID: runID,
          sequence: 3,
          event: .messageAppended(
            GatewayTestValues.request(runID: runID).initialMessages[0]
          )
        ),
      ],
      runID: runID,
      code: .eventAfterTerminal
    )
  }

  @Test
  func reportsPostTerminalViolationToExistingSubscriber() async throws {
    let driver = ControllableGatewayRunDriver()
    let service = HexGatewayService(driver: driver)
    let transport = InProcessHexGatewayTransport(service: service)
    _ = try await transport.handshake(GatewayTestValues.handshakeRequest())
    let runID = GatewayTestValues.runID()
    let request = GatewayTestValues.request(runID: runID)
    _ = try await transport.startRun(request)
    await driver.waitUntilStarted(runID)
    let stream = try await transport.eventRecords(after: GatewayEventCursor(runID: runID))

    await driver.yieldAndWait(
      GatewayTestValues.record(runID: runID, sequence: 1, event: .runStarted)
    )
    await driver.yieldAndWait(
      GatewayTestValues.record(runID: runID, sequence: 2, event: .runCompleted)
    )
    await driver.yieldAndWait(
      GatewayTestValues.record(
        runID: runID,
        sequence: 3,
        event: .messageAppended(request.initialMessages[0])
      )
    )

    do {
      _ = try await GatewayTestValues.collect(stream)
      Issue.record("Expected a live post-terminal violation.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .eventAfterTerminal)
    }
  }

  @Test
  func rejectsProducerEndWithoutTerminalRecord() async {
    let runID = GatewayTestValues.runID()
    await expectFailure(
      records: [
        GatewayTestValues.record(runID: runID, sequence: 1, event: .runStarted)
      ],
      runID: runID,
      code: .producerEndedWithoutTerminalEvent
    )
  }

  private func replayAfterDriving(
    _ records: [AgentEventRecord],
    runID: AgentRunID
  ) async throws -> [AgentEventRecord] {
    let driver = ControllableGatewayRunDriver()
    let service = HexGatewayService(driver: driver)
    let transport = InProcessHexGatewayTransport(service: service)
    _ = try await transport.handshake(GatewayTestValues.handshakeRequest())
    _ = try await transport.startRun(GatewayTestValues.request(runID: runID))
    await driver.waitUntilStarted(runID)
    for record in records {
      await driver.yield(record, to: runID)
    }
    await driver.finish(runID)
    await driver.waitUntilStopped(runID)
    let stream = try await transport.eventRecords(after: GatewayEventCursor(runID: runID))
    return try await GatewayTestValues.collect(stream)
  }

  private func expectFailure(
    records: [AgentEventRecord],
    runID: AgentRunID,
    code: GatewayFailureCode
  ) async {
    do {
      _ = try await replayAfterDriving(records, runID: runID)
      Issue.record("Expected gateway ordering failure.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == code)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }
}
