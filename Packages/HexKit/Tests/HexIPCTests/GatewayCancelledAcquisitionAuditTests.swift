import Testing

@testable import HexIPC

@Suite("Gateway cancelled acquisition audit")
struct GatewayCancelledAcquisitionAuditTests {
  @Test
  func cancellationPromptlyReleasesReservationWithoutTearingDownReplacement() async throws {
    let configuration = try #require(
      GatewayConfiguration(
        maximumWireBytes: 32_768,
        maximumRetainedRecordsPerRun: 1,
        subscriberBufferCapacity: 1,
        maximumSubscribersPerRun: 1
      )
    )
    let transport = HangingGatewayTransport(holdsStreamAcquisition: true)
    let client = HexGatewayClient(transport: transport, configuration: configuration)
    _ = try await client.connect()
    let runID = GatewayTestValues.runID(250)
    let invocationID = GatewayTestValues.invocationID(250)

    let cancelled = Task {
      try await client.eventRecords(for: runID, invocationID: invocationID)
    }
    await transport.waitForPendingStreamCount(1)
    cancelled.cancel()
    for _ in 0..<100 {
      await Task.yield()
    }

    let reservationCountAfterCancellation = await client.eventStreamReservations.count
    #expect(reservationCountAfterCancellation == 0)
    guard reservationCountAfterCancellation == 0 else {
      try await client.disconnect()
      _ = try? await cancelled.value
      return
    }

    let replacement = Task {
      try await client.eventRecords(for: runID, invocationID: invocationID)
    }
    for _ in 0..<100 {
      await Task.yield()
    }
    let pendingCount = await transport.pendingStreamCount
    #expect(pendingCount == 2)
    guard pendingCount == 2 else {
      try await client.disconnect()
      _ = try? await cancelled.value
      _ = try? await replacement.value
      return
    }

    await transport.resolveNextPendingStream()
    await expectCancellation(cancelled)
    for _ in 0..<100 {
      await Task.yield()
    }
    #expect(await client.eventStreamReservations.count == 1)
    #expect(await client.eventStreams.isEmpty)
    #expect(await transport.activeStreamCount == 0)

    await transport.resolveNextPendingStream()
    let replacementStream = try await replacement.value
    #expect(await client.eventStreamReservations.isEmpty)
    #expect(await client.eventStreams.count == 1)
    #expect(await transport.activeStreamCount == 1)

    try await client.disconnect()
    _ = replacementStream
  }

  @Test
  func cancelledLateFailureCannotMutateReplacementGeneration() async throws {
    let configuration = try #require(
      GatewayConfiguration(
        maximumWireBytes: 32_768,
        maximumRetainedRecordsPerRun: 1,
        subscriberBufferCapacity: 1,
        maximumSubscribersPerRun: 1
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
    for _ in 0..<100 {
      await Task.yield()
    }
    #expect(await client.eventStreamReservations.isEmpty)

    _ = try await client.connect()
    let replacement = Task {
      try await client.eventRecords(for: runID, invocationID: invocationID)
    }
    for _ in 0..<100 {
      await Task.yield()
    }
    let pendingCount = await transport.pendingStreamCount
    #expect(pendingCount == 2)
    guard pendingCount == 2 else {
      try await client.disconnect()
      _ = try? await cancelled.value
      _ = try? await replacement.value
      return
    }

    await transport.failNextPendingStream(message: "secret stale transport failure")
    await expectCancellation(cancelled)
    #expect(await client.eventStreamReservations.count == 1)
    #expect(await client.eventStreams.isEmpty)

    await transport.resolveNextPendingStream()
    let replacementStream = try await replacement.value
    #expect(await client.eventStreamReservations.isEmpty)
    #expect(await client.eventStreams.count == 1)

    try await client.disconnect()
    _ = replacementStream
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
