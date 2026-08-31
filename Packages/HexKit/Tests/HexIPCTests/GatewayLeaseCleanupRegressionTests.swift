import Testing

@testable import HexIPC

@Suite("Gateway lease cleanup regressions")
struct GatewayLeaseCleanupRegressionTests {
  @Test
  func cancelledSuccessfulHandshakeReleasesItsPhysicalLease() async throws {
    let transport = HostileLifecycleGatewayTransport()
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()

    let cancelledConnection = Task { try await client.connect() }
    await transport.waitUntilHandshakeIsPending(2)
    cancelledConnection.cancel()
    await transport.resolveHandshake(2, instanceSeed: 220)

    do {
      _ = try await cancelledConnection.value
      Issue.record("Expected cancellation.")
    } catch is CancellationError {
      // Expected.
    }

    #expect(await transport.disconnectCount == 1)
  }

  @Test
  func cancelledOlderHandshakeCleanupCannotTearDownReplacementLease() async throws {
    let transport = HostileLifecycleGatewayTransport()
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()

    let olderConnection = Task { try await client.connect() }
    await transport.waitUntilHandshakeIsPending(2)
    let replacementConnection = Task { try await client.connect() }
    await transport.waitUntilHandshakeIsPending(3)
    await transport.resolveHandshake(3, instanceSeed: 218)
    _ = try await replacementConnection.value

    olderConnection.cancel()
    await transport.resolveHandshake(2, instanceSeed: 219)
    do {
      _ = try await olderConnection.value
      Issue.record("Expected the older connection to remain cancelled.")
    } catch is CancellationError {
      // Expected.
    } catch {
      Issue.record("Expected cancellation, received: \(error)")
    }
    #expect(await transport.disconnectCount == 1)

    let runID = GatewayTestValues.runID(218)
    let stream = try await client.eventRecords(
      for: runID,
      invocationID: GatewayTestValues.invocationID(218)
    )
    await transport.emit(
      GatewayTestValues.record(runID: runID, sequence: 1, event: .runStarted)
    )
    await transport.emit(
      GatewayTestValues.record(runID: runID, sequence: 2, event: .runCompleted)
    )
    await transport.finishStream()
    #expect(try await GatewayTestValues.collect(stream).count == 2)
  }

  @Test
  func rejectedHandshakeResponseReleasesItsPhysicalLease() async {
    let transport = HostileLifecycleGatewayTransport(
      selectedVersion: GatewayProtocolVersion(major: 99, minor: 0)
    )
    let client = HexGatewayClient(transport: transport)

    do {
      _ = try await client.connect()
      Issue.record("Expected the unsupported response to be rejected.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .incompatibleProtocolVersion)
    } catch {
      Issue.record("Expected a gateway failure, received: \(error)")
    }

    #expect(await transport.disconnectCount == 1)
  }
}
