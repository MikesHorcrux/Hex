import Testing

@testable import HexIPC

@Suite("Gateway client stream capacity regressions")
struct GatewayClientStreamCapacityRegressionTests {
  @Test
  func clientEnforcesItsConfiguredLiveStreamCapacity() async throws {
    let configuration = try #require(
      GatewayConfiguration(
        maximumWireBytes: 32_768,
        maximumRetainedRecordsPerRun: 2,
        subscriberBufferCapacity: 2,
        maximumSubscribersPerRun: 2
      )
    )
    let transport = HangingGatewayTransport()
    let client = HexGatewayClient(transport: transport, configuration: configuration)
    _ = try await client.connect()
    let runID = GatewayTestValues.runID(227)
    let invocationID = GatewayTestValues.invocationID(227)
    let firstStream = try await client.eventRecords(
      for: runID,
      invocationID: invocationID
    )
    _ = try await client.eventRecords(for: runID, invocationID: invocationID)

    do {
      _ = try await client.eventRecords(for: runID, invocationID: invocationID)
      Issue.record("Expected the third live stream to exceed the client capacity.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .capacityExceeded)
    } catch {
      Issue.record("Expected a gateway failure, received: \(error)")
    }

    #expect(await client.eventStreams.count == configuration.maximumSubscribersPerRun)
    #expect(await transport.activeStreamCount == configuration.maximumSubscribersPerRun)

    let cancelledCollector = Task {
      for try await _ in firstStream {}
    }
    cancelledCollector.cancel()
    _ = try? await cancelledCollector.value
    while await client.eventStreams.count == configuration.maximumSubscribersPerRun {
      await Task.yield()
    }
    while await transport.activeStreamCount == configuration.maximumSubscribersPerRun {
      await Task.yield()
    }

    _ = try await client.eventRecords(for: runID, invocationID: invocationID)
    #expect(await client.eventStreams.count == configuration.maximumSubscribersPerRun)
    #expect(await transport.activeStreamCount == configuration.maximumSubscribersPerRun)
    try await client.disconnect()
  }

  @Test
  func concurrentPendingStreamsReserveCapacityAndCancellationReleasesExactlyOnce() async throws {
    let configuration = try #require(
      GatewayConfiguration(
        maximumWireBytes: 32_768,
        maximumRetainedRecordsPerRun: 2,
        subscriberBufferCapacity: 2,
        maximumSubscribersPerRun: 2
      )
    )
    let transport = HangingGatewayTransport(holdsStreamAcquisition: true)
    let client = HexGatewayClient(transport: transport, configuration: configuration)
    _ = try await client.connect()
    let runID = GatewayTestValues.runID(228)
    let invocationID = GatewayTestValues.invocationID(228)

    let cancelledAcquisition = Task {
      try await client.eventRecords(for: runID, invocationID: invocationID)
    }
    await transport.waitForPendingStreamCount(1)
    let retainedAcquisition = Task {
      try await client.eventRecords(for: runID, invocationID: invocationID)
    }
    await transport.waitForPendingStreamCount(2)

    do {
      _ = try await client.eventRecords(for: runID, invocationID: invocationID)
      Issue.record("Expected pending reservations to consume the configured capacity.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .capacityExceeded)
    } catch {
      Issue.record("Expected a gateway failure, received: \(error)")
    }
    #expect(await transport.pendingStreamCount == 2)
    #expect(await client.eventStreamReservations.count == 2)

    cancelledAcquisition.cancel()
    await transport.resolvePendingStreams()
    do {
      _ = try await cancelledAcquisition.value
      Issue.record("Expected the cancelled stream acquisition to stay cancelled.")
    } catch is CancellationError {
      // Expected.
    } catch {
      Issue.record("Expected cancellation, received: \(error)")
    }
    let retainedStream = try await retainedAcquisition.value
    await transport.waitForActiveStreamCount(1)

    #expect(await client.eventStreamReservations.isEmpty)
    #expect(await client.eventStreams.count == 1)
    #expect(await transport.activeStreamCount == 1)
    _ = retainedStream
    try await client.disconnect()
  }

  @Test
  func liveStreamsAcrossDistinctRunsRemainGloballyBounded() async throws {
    let configuration = try #require(
      GatewayConfiguration(
        maximumWireBytes: 32_768,
        maximumRetainedRecordsPerRun: 2,
        subscriberBufferCapacity: 2,
        maximumSubscribersPerRun: 1,
        maximumRememberedRuns: 2
      )
    )
    let transport = HangingGatewayTransport()
    let client = HexGatewayClient(transport: transport, configuration: configuration)
    _ = try await client.connect()

    _ = try await client.eventRecords(
      for: GatewayTestValues.runID(239),
      invocationID: GatewayTestValues.invocationID(239)
    )
    _ = try await client.eventRecords(
      for: GatewayTestValues.runID(240),
      invocationID: GatewayTestValues.invocationID(240)
    )

    do {
      _ = try await client.eventRecords(
        for: GatewayTestValues.runID(241),
        invocationID: GatewayTestValues.invocationID(241)
      )
      Issue.record("Expected the global client stream bound to reject another run.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .capacityExceeded)
    } catch {
      Issue.record("Expected a gateway failure, received: \(error)")
    }

    #expect(await client.eventStreams.count == 2)
    #expect(await transport.activeStreamCount == 2)
    try await client.disconnect()
  }
}
