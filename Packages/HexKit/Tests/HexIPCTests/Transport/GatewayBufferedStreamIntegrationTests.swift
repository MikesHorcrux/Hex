import HexCore
import HexIPC
import Testing

@Suite("Gateway buffered stream integration")
struct GatewayBufferedStreamIntegrationTests {
  @Test("Standard service and client retain a token burst during slow serial UI acknowledgements")
  func slowAcknowledgingConsumerReceivesWholeLiveReply() async throws {
    let driver = ControllableGatewayRunDriver()
    let service = HexGatewayService(driver: driver)
    let transport = InProcessHexGatewayTransport(service: service)
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()
    let runID = GatewayTestValues.runID(181)
    let request = GatewayTestValues.request(runID: runID)
    let start = try await client.startRun(request)
    let invocationID = try #require(start.invocationID)
    await driver.waitUntilStarted(runID)
    let stream = try await client.eventRecords(for: runID, invocationID: invocationID)
    let fragments = (0..<100).map { "token-\($0) " }
    let finalText = fragments.joined()
    let events: [AgentEvent] =
      [
        .runStarted,
        .messageAppended(request.initialMessages[0]),
        .inferenceRequested(
          InferenceRequest(
            providerID: ProviderID(rawValue: "fixture"), modelID: request.modelID,
            messages: request.initialMessages)),
        .inferenceEvent(.started(providerResponseID: nil)),
      ] + fragments.map { .inferenceEvent(.textDelta($0)) } + [
        .inferenceEvent(.completed(.stop)),
        .messageAppended(Message(role: .assistant, content: [.text(finalText)])),
        .runCompleted,
      ]
    let expected = events.enumerated().map {
      GatewayTestValues.record(runID: runID, sequence: UInt64($0.offset + 1), event: $0.element)
    }
    let gate = ConsumerGate()
    let consumer = Task {
      var records: [AgentEventRecord] = []
      for try await envelope in stream {
        #expect(try await client.shouldApply(envelope))
        if records.isEmpty { await gate.wait() }
        // Model a UI that must persist/project each record before advancing its replay cursor.
        try await Task.sleep(for: .milliseconds(1))
        records.append(envelope.record)
        try await client.acknowledge(envelope)
      }
      return records
    }

    do {
      // No consumer acknowledgement is allowed until the full burst crossed the real service.
      // This is larger than the old count-only queue, while far below the actual byte allowance.
      for record in expected { await driver.yieldAndWait(record) }
      await driver.finish(runID)
      await gate.release()
      let received = try await consumer.value
      #expect(received == expected)
      #expect(received.last?.event == .runCompleted)
      #expect(
        received.compactMap { record -> String? in
          guard case .inferenceEvent(.textDelta(let text)) = record.event else { return nil }
          return text
        }.joined() == finalText)
      #expect(
        await client.acknowledgedCursor(for: runID, invocationID: invocationID).sequence
          == UInt64(expected.count))
      #expect(await driver.invocationCount(for: runID) == 1)
      try await client.disconnect()
      try await service.shutdown(timeout: .seconds(2))
    } catch {
      await gate.release()
      consumer.cancel()
      _ = try? await consumer.value
      await driver.finish(runID)
      try? await client.disconnect()
      try? await service.shutdown(timeout: .seconds(2))
      throw error
    }
  }

  private actor ConsumerGate {
    private var isReleased = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
      guard !isReleased else { return }
      await withCheckedContinuation { waiter = $0 }
    }

    func release() {
      isReleased = true
      waiter?.resume()
      waiter = nil
    }
  }
}
