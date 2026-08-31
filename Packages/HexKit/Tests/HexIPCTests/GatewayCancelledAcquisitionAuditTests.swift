import Testing

@testable import HexIPC

@Suite("Gateway cancelled acquisition audit")
struct GatewayCancelledAcquisitionAuditTests {
  @Test(arguments: 0..<100)
  func cancellationQueuesImmediateReplacementBehindPhysicalLimit(_ iteration: Int) async throws {
    let configuration = try #require(
      GatewayConfiguration(
        maximumWireBytes: 32_768,
        maximumRetainedRecordsPerRun: 1,
        subscriberBufferCapacity: 1,
        maximumSubscribersPerRun: 1,
        maximumRememberedRuns: 1
      )
    )
    let transport = HangingGatewayTransport(holdsStreamAcquisition: true)
    let client = HexGatewayClient(transport: transport, configuration: configuration)
    _ = try await client.connect()
    let identitySeed = UInt8(truncatingIfNeeded: 100 + iteration)
    let runID = GatewayTestValues.runID(identitySeed)
    let invocationID = GatewayTestValues.invocationID(identitySeed)

    let cancelled = Task {
      try await client.eventRecords(for: runID, invocationID: invocationID)
    }
    await transport.waitForPendingStreamCount(1)
    cancelled.cancel()
    let replacement = Task {
      try await client.eventRecords(for: runID, invocationID: invocationID)
    }

    await transport.allowPendingStreamAcquisitionsToResolve()
    await expectCancellation(cancelled)
    let replacementStream = try await replacement.value
    await transport.waitForActiveStreamCount(1)

    #expect(await transport.maximumPendingStreamCount == 1)
    #expect(await transport.activeStreamCount == 1)

    try await client.disconnect()
    _ = replacementStream
  }

  @Test
  func cancelledLateFailureCannotMutateReconnectedReplacementGeneration() async throws {
    let configuration = try #require(
      GatewayConfiguration(
        maximumWireBytes: 32_768,
        maximumRetainedRecordsPerRun: 1,
        subscriberBufferCapacity: 1,
        maximumSubscribersPerRun: 1,
        maximumRememberedRuns: 1
      )
    )
    let transport = HangingGatewayTransport(holdsStreamAcquisition: true)
    let client = HexGatewayClient(transport: transport, configuration: configuration)
    _ = try await client.connect()
    let runID = GatewayTestValues.runID(251)
    let invocationID = GatewayTestValues.invocationID(251)

    let cancelled = Task {
      try await client.eventRecords(for: runID, invocationID: invocationID)
    }
    await transport.waitForPendingStreamCount(1)
    cancelled.cancel()
    _ = try await client.connect()
    let replacement = Task {
      try await client.eventRecords(for: runID, invocationID: invocationID)
    }

    await transport.failPendingStreamAcquisitionsAndAllowFutureOnes(
      message: "secret stale transport failure"
    )
    await expectCancellation(cancelled)
    let replacementStream = try await replacement.value
    await transport.waitForActiveStreamCount(1)

    #expect(await transport.maximumPendingStreamCount == 1)
    #expect(await transport.activeStreamCount == 1)

    try await client.disconnect()
    _ = replacementStream
  }

  @Test
  func repeatedIgnoredCancellationsNeverStartAnotherPhysicalAcquisition() async throws {
    let configuration = try #require(
      GatewayConfiguration(
        maximumWireBytes: 32_768,
        maximumRetainedRecordsPerRun: 1,
        subscriberBufferCapacity: 1,
        maximumSubscribersPerRun: 1,
        maximumRememberedRuns: 1
      )
    )
    let transport = HangingGatewayTransport(holdsStreamAcquisition: true)
    let client = HexGatewayClient(transport: transport, configuration: configuration)
    _ = try await client.connect()
    let runID = GatewayTestValues.runID(252)
    let invocationID = GatewayTestValues.invocationID(252)

    var acquisition = Task {
      try await client.eventRecords(for: runID, invocationID: invocationID)
    }
    await transport.waitForPendingStreamCount(1)
    var cancelledAcquisitions:
      [Task<AsyncThrowingStream<GatewayEventEnvelope, any Error>, any Error>] = []

    for _ in 0..<20 {
      acquisition.cancel()
      cancelledAcquisitions.append(acquisition)
      acquisition = Task {
        try await client.eventRecords(for: runID, invocationID: invocationID)
      }
    }

    await transport.allowPendingStreamAcquisitionsToResolve()
    for cancelledAcquisition in cancelledAcquisitions {
      await expectCancellation(cancelledAcquisition)
    }
    let retainedStream = try await acquisition.value
    await transport.waitForActiveStreamCount(1)

    #expect(await transport.maximumPendingStreamCount == 1)
    #expect(await transport.activeStreamCount == 1)

    try await client.disconnect()
    _ = retainedStream
  }

  @Test
  func replacementQueueRetainsOnlyConfiguredLogicalCapacity() async throws {
    let configuration = try #require(
      GatewayConfiguration(
        maximumWireBytes: 32_768,
        maximumRetainedRecordsPerRun: 1,
        subscriberBufferCapacity: 1,
        maximumSubscribersPerRun: 1,
        maximumRememberedRuns: 1
      )
    )
    let transport = HangingGatewayTransport(holdsStreamAcquisition: true)
    let client = HexGatewayClient(transport: transport, configuration: configuration)
    _ = try await client.connect()
    let runID = GatewayTestValues.runID(253)
    let invocationID = GatewayTestValues.invocationID(253)

    let cancelled = Task {
      try await client.eventRecords(for: runID, invocationID: invocationID)
    }
    await transport.waitForPendingStreamCount(1)
    cancelled.cancel()
    let candidates = (0..<2).map { _ in
      Task {
        try await client.eventRecords(for: runID, invocationID: invocationID)
      }
    }

    await transport.allowPendingStreamAcquisitionsToResolve()
    await expectCancellation(cancelled)

    var retainedStreams: [AsyncThrowingStream<GatewayEventEnvelope, any Error>] = []
    var capacityFailureCount = 0
    for candidate in candidates {
      do {
        retainedStreams.append(try await candidate.value)
      } catch let failure as GatewayFailure {
        #expect(failure.code == .capacityExceeded)
        capacityFailureCount += 1
      } catch {
        Issue.record("Expected a bounded-capacity result, received: \(error)")
      }
    }
    await transport.waitForActiveStreamCount(1)

    #expect(retainedStreams.count == 1)
    #expect(capacityFailureCount == 1)
    #expect(await transport.maximumPendingStreamCount == 1)
    #expect(await transport.activeStreamCount == 1)

    try await client.disconnect()
    _ = retainedStreams
  }

  private func expectCancellation<Value: Sendable>(
    _ task: Task<Value, any Error>
  ) async {
    do {
      _ = try await task.value
      Issue.record("Expected cancellation from the stale stream acquisition.")
    } catch is CancellationError {
      // Expected.
    } catch {
      Issue.record("Expected cancellation, received: \(error)")
    }
  }
}
