import HexCore
import HexIPC
import Testing

@Suite("Gateway service wire acceptance")
struct GatewayServiceWireAcceptanceTests {
  @Test
  func rejectsOversizedDriverRecordBeforeAdvancingTheRun() async throws {
    let configuration = try #require(
      GatewayConfiguration(
        maximumWireBytes: 512,
        maximumRetainedRecordsPerRun: 8,
        subscriberBufferCapacity: 8
      )
    )
    let runID = GatewayTestValues.runID()
    let oversizedRecord = GatewayTestValues.record(
      runID: runID,
      sequence: 2,
      event: .messageAppended(
        Message(
          role: .assistant,
          content: [.text(String(repeating: "x", count: 4_096))]
        )
      )
    )

    try await assertRejectedBeforeMutation(
      oversizedRecord,
      expectedCode: .payloadTooLarge,
      configuration: configuration
    )
  }

  @Test
  func rejectsUnencodableDriverRecordBeforeAdvancingTheRun() async throws {
    let runID = GatewayTestValues.runID()
    let unencodableRecord = GatewayTestValues.record(
      runID: runID,
      sequence: 2,
      event: .messageAppended(
        Message(
          role: .assistant,
          content: [
            .toolCall(
              ToolCall(
                id: ToolCallID(rawValue: "noncanonical-number"),
                name: "echo",
                arguments: ["value": .number(42.0)]
              )
            )
          ]
        )
      )
    )

    try await assertRejectedBeforeMutation(
      unencodableRecord,
      expectedCode: .malformedPayload,
      configuration: .standard
    )
  }

  @Test
  func retainedWireByteBudgetTrimsReplayBeforeTheRecordCountLimit() async throws {
    let runID = GatewayTestValues.runID()
    let records = [
      GatewayTestValues.record(runID: runID, sequence: 1, event: .runStarted),
      GatewayTestValues.record(
        runID: runID,
        sequence: 2,
        event: .messageAppended(
          Message(
            role: .assistant,
            content: [.text(String(repeating: "bounded", count: 256))]
          )
        )
      ),
      GatewayTestValues.record(runID: runID, sequence: 3, event: .runCompleted),
    ]
    let probeCodec = GatewayWireCodec(configuration: .standard)
    let wireByteCounts = try records.map { try probeCodec.encode($0).count }
    let largestRecordBytes = try #require(wireByteCounts.max())
    let retainedTailBytes = wireByteCounts[1] + wireByteCounts[2]
    let configuration = try #require(
      GatewayConfiguration(
        maximumWireBytes: largestRecordBytes,
        maximumRetainedRecordsPerRun: 10,
        maximumRetainedWireBytesPerRun: retainedTailBytes,
        subscriberBufferCapacity: 10
      )
    )
    let driver = ControllableGatewayRunDriver()
    let service = HexGatewayService(driver: driver, configuration: configuration)
    let handshake = try await service.handshake(GatewayTestValues.handshakeRequest())
    let start = try await service.startRun(
      GatewayTestValues.request(runID: runID),
      sessionID: handshake.sessionID
    )
    let invocationID = try #require(start.invocationID)
    await driver.waitUntilStarted(runID)

    for record in records {
      await driver.yieldAndWait(record)
    }
    await driver.finish(runID)
    await driver.waitUntilStopped(runID)

    do {
      _ = try await service.eventRecords(
        after: GatewayEventCursor(runID: runID, invocationID: invocationID),
        sessionID: handshake.sessionID
      )
      Issue.record("Expected cursor zero to predate the byte-bounded replay window.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .replayUnavailable)
    }

    let retainedTail = try await service.eventRecords(
      after: GatewayEventCursor(
        runID: runID,
        invocationID: invocationID,
        sequence: 1
      ),
      sessionID: handshake.sessionID
    )
    #expect(try await GatewayTestValues.collect(retainedTail) == Array(records.dropFirst()))
  }

  private func assertRejectedBeforeMutation(
    _ rejectedRecord: AgentEventRecord,
    expectedCode: GatewayFailureCode,
    configuration: GatewayConfiguration
  ) async throws {
    let runID = rejectedRecord.runID
    let driver = ControllableGatewayRunDriver()
    let service = HexGatewayService(driver: driver, configuration: configuration)
    let handshake = try await service.handshake(GatewayTestValues.handshakeRequest())
    let start = try await service.startRun(
      GatewayTestValues.request(runID: runID),
      sessionID: handshake.sessionID
    )
    let invocationID = try #require(start.invocationID)
    await driver.waitUntilStarted(runID)
    let liveStream = try await service.eventRecords(
      after: GatewayEventCursor(runID: runID, invocationID: invocationID),
      sessionID: handshake.sessionID
    )
    var liveIterator = liveStream.makeAsyncIterator()
    let startRecord = GatewayTestValues.record(runID: runID, sequence: 1, event: .runStarted)

    await driver.yieldAndWait(startRecord)
    #expect(try await liveIterator.next() == startRecord)
    await driver.yieldAndWait(rejectedRecord)
    await driver.waitUntilStopped(runID)

    do {
      _ = try await liveIterator.next()
      Issue.record("Expected the rejected driver record to terminate the live stream.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == expectedCode)
    }

    do {
      _ = try await service.eventRecords(
        after: GatewayEventCursor(
          runID: runID,
          invocationID: invocationID,
          sequence: rejectedRecord.sequence
        ),
        sessionID: handshake.sessionID
      )
      Issue.record("Expected the rejected sequence to remain above the high-water mark.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .invalidCursor)
    }

    let postStartReplay = try await service.eventRecords(
      after: GatewayEventCursor(
        runID: runID,
        invocationID: invocationID,
        sequence: startRecord.sequence
      ),
      sessionID: handshake.sessionID
    )
    var replayIterator = postStartReplay.makeAsyncIterator()
    do {
      _ = try await replayIterator.next()
      Issue.record("Expected failure without replaying the rejected record.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == expectedCode)
    }
  }
}
