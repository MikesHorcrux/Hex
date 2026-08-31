import Foundation
import HexCore
import HexIPC
import Testing

@Suite("Gateway connection lifecycle")
struct GatewayConnectionLifecycleTests {
  @Test
  func clientRejectsHandshakeVersionOutsideItsOfferedRange() async throws {
    let unsupported = GatewayProtocolVersion(major: 99, minor: 0)
    let transport = HostileLifecycleGatewayTransport(selectedVersion: unsupported)
    let client = HexGatewayClient(
      transport: transport,
      minimumVersion: .current,
      maximumVersion: .current
    )

    do {
      _ = try await client.connect()
      Issue.record("Expected the unoffered selected version to be rejected.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .incompatibleProtocolVersion)
    }
  }

  @Test
  func clientRejectsMalformedOfferedVersionRangeBeforeHandshake() async {
    let transport = HostileLifecycleGatewayTransport()
    let client = HexGatewayClient(
      transport: transport,
      minimumVersion: GatewayProtocolVersion(major: 2, minor: 0),
      maximumVersion: .current
    )

    do {
      _ = try await client.connect()
      Issue.record("Expected the malformed offered version range to be rejected.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .malformedVersionRange)
    } catch {
      Issue.record("Expected a gateway failure, received: \(error)")
    }
  }

  @Test
  func clientRejectsInvalidHandshakeIdentitiesAndActiveRunSnapshots() async {
    let zeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    let runID = GatewayTestValues.runID(230)
    let invocationID = GatewayTestValues.invocationID(230)
    let invalidResponses = [
      handshakeResponse(
        sessionID: GatewaySessionID(rawValue: zeroUUID)
      ),
      handshakeResponse(
        gatewayInstanceID: GatewayInstanceID(rawValue: zeroUUID)
      ),
      handshakeResponse(
        activeRun: GatewayRunSnapshot(
          runID: AgentRunID(rawValue: zeroUUID),
          invocationID: invocationID,
          phase: .starting,
          latestSequence: 0
        )
      ),
      handshakeResponse(
        activeRun: GatewayRunSnapshot(
          runID: runID,
          invocationID: GatewayRunInvocationID(rawValue: zeroUUID),
          phase: .starting,
          latestSequence: 0
        )
      ),
      handshakeResponse(
        activeRun: GatewayRunSnapshot(
          runID: runID,
          invocationID: invocationID,
          phase: .starting,
          latestSequence: 1
        )
      ),
      handshakeResponse(
        activeRun: GatewayRunSnapshot(
          runID: runID,
          invocationID: invocationID,
          phase: .running,
          latestSequence: 0
        )
      ),
      handshakeResponse(
        activeRun: GatewayRunSnapshot(
          runID: runID,
          invocationID: invocationID,
          phase: .terminal,
          latestSequence: 1
        )
      ),
      handshakeResponse(
        activeRun: GatewayRunSnapshot(
          runID: runID,
          invocationID: invocationID,
          phase: .cancelling,
          latestSequence: UInt64.max
        )
      ),
    ]

    for response in invalidResponses {
      let client = HexGatewayClient(
        transport: HostileLifecycleGatewayTransport(initialResponse: response)
      )
      do {
        _ = try await client.connect()
        Issue.record("Expected the malformed handshake field to be rejected.")
      } catch let failure as GatewayFailure {
        #expect(failure.code == .malformedPayload)
        #expect(failure.message == "The gateway returned an invalid handshake response.")
      } catch {
        Issue.record("Expected a gateway failure, received: \(error)")
      }
    }
  }

  @Test
  func clientAcceptsConsistentActiveRunSnapshot() async throws {
    let activeRun = GatewayRunSnapshot(
      runID: GatewayTestValues.runID(231),
      invocationID: GatewayTestValues.invocationID(231),
      phase: .running,
      latestSequence: 1
    )
    let client = HexGatewayClient(
      transport: HostileLifecycleGatewayTransport(
        initialResponse: handshakeResponse(activeRun: activeRun)
      )
    )

    let result = try await client.connect()
    #expect(result.response.activeRun == activeRun)
  }

  @Test
  func cancelledConnectCannotCommitWhenTransportIgnoresCancellation() async throws {
    let transport = HostileLifecycleGatewayTransport()
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()
    let runID = GatewayTestValues.runID(241)
    let invocationID = GatewayTestValues.invocationID(241)
    let record = GatewayTestValues.record(runID: runID, sequence: 1, event: .runStarted)
    try await client.acknowledge(record, invocationID: invocationID)

    let cancelledConnect = Task { try await client.connect() }
    await transport.waitUntilHandshakeIsPending(2)
    cancelledConnect.cancel()
    await transport.resolveHandshake(2, instanceSeed: 242)

    do {
      _ = try await cancelledConnect.value
      Issue.record("Expected cancellation.")
    } catch is CancellationError {
      // Expected.
    }
    #expect(
      await client.acknowledgedCursor(
        for: runID,
        invocationID: invocationID
      ).sequence == 1
    )
  }

  @Test
  func staleHandshakeFailureAfterNewerConnectIsRedactedAsSuperseded() async throws {
    let transport = HostileLifecycleGatewayTransport()
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()
    let stale = Task { try await client.connect() }
    await transport.waitUntilHandshakeIsPending(2)
    let current = Task { try await client.connect() }
    await transport.waitUntilHandshakeIsPending(3)
    await transport.resolveHandshake(3, instanceSeed: 243)
    _ = try await current.value
    await transport.failHandshake(2, message: "secret handshake transport details")

    do {
      _ = try await stale.value
      Issue.record("Expected a superseded operation.")
    } catch let failure as GatewayFailure {
      expectSuperseded(failure)
    }
  }

  @Test
  func disconnectInvalidatesPendingConnect() async throws {
    let transport = HostileLifecycleGatewayTransport()
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()
    let stale = Task { try await client.connect() }
    await transport.waitUntilHandshakeIsPending(2)
    try await client.disconnect()
    await transport.resolveHandshake(2, instanceSeed: 244)

    do {
      _ = try await stale.value
      Issue.record("Expected the post-disconnect handshake to be rejected.")
    } catch let failure as GatewayFailure {
      expectSuperseded(failure)
    }
  }

  @Test
  func cancelledDisconnectCannotCommitWhenTransportIgnoresCancellation() async throws {
    let transport = HostileLifecycleGatewayTransport(holdsDisconnect: true)
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()

    let disconnect = Task { try await client.disconnect() }
    await transport.waitUntilDisconnectIsPending()
    disconnect.cancel()
    await transport.resolveDisconnect()

    do {
      try await disconnect.value
      Issue.record("Expected cancellation from the disconnect operation.")
    } catch is CancellationError {
      // Expected.
    }
  }

  @Test
  func delayedDisconnectCannotRegressNewerConnection() async throws {
    let transport = HostileLifecycleGatewayTransport(holdsDisconnect: true)
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()

    let delayedDisconnect = Task { try await client.disconnect() }
    await transport.waitUntilDisconnectIsPending()
    let reconnect = Task { try await client.connect() }
    await transport.waitUntilHandshakeIsPending(2)
    await transport.resolveHandshake(2, instanceSeed: 235)
    _ = try await reconnect.value

    await transport.resolveDisconnect()
    await expectSuperseded(delayedDisconnect)

    let runID = GatewayTestValues.runID(235)
    let invocationID = GatewayTestValues.invocationID(235)
    let stream = try await client.eventRecords(for: runID, invocationID: invocationID)
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
  func gatewayRestartInvalidatesPendingStartBeforeItCanEraseNewCursor() async throws {
    let transport = HostileLifecycleGatewayTransport()
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()
    let runID = GatewayTestValues.runID(245)
    let staleInvocationID = GatewayTestValues.invocationID(245)
    let currentInvocationID = GatewayTestValues.invocationID(246)
    let staleStart = Task {
      try await client.startRun(GatewayTestValues.request(runID: runID))
    }
    await transport.waitUntilStartIsPending()
    let reconnect = Task { try await client.connect() }
    await transport.waitUntilHandshakeIsPending(2)
    await transport.resolveHandshake(2, instanceSeed: 246)
    _ = try await reconnect.value
    let record = GatewayTestValues.record(runID: runID, sequence: 1, event: .runStarted)
    try await client.acknowledge(record, invocationID: currentInvocationID)

    await transport.resolveStart(runID: runID, invocationID: staleInvocationID)
    do {
      _ = try await staleStart.value
      Issue.record("Expected the pre-restart start to be rejected.")
    } catch let failure as GatewayFailure {
      expectSuperseded(failure)
    }
    #expect(
      await client.acknowledgedCursor(
        for: runID,
        invocationID: currentInvocationID
      ).sequence == 1
    )
  }

  @Test
  func gatewayRestartRedactsPendingStartFailure() async throws {
    let transport = HostileLifecycleGatewayTransport()
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()
    let runID = GatewayTestValues.runID(255)
    let currentInvocationID = GatewayTestValues.invocationID(255)
    let staleStart = Task {
      try await client.startRun(GatewayTestValues.request(runID: runID))
    }
    await transport.waitUntilStartIsPending()

    let reconnect = Task { try await client.connect() }
    await transport.waitUntilHandshakeIsPending(2)
    await transport.resolveHandshake(2, instanceSeed: 255)
    _ = try await reconnect.value
    let record = GatewayTestValues.record(runID: runID, sequence: 1, event: .runStarted)
    try await client.acknowledge(record, invocationID: currentInvocationID)

    await transport.failStart(message: "secret stale start failure")
    await expectSuperseded(staleStart)
    #expect(
      await client.acknowledgedCursor(
        for: runID,
        invocationID: currentInvocationID
      ).sequence == 1
    )
  }

  @Test
  func cancelResponseMustEchoRequestedRunAndInvocation() async throws {
    let transport = HostileLifecycleGatewayTransport()
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()
    let requestedRunID = GatewayTestValues.runID(247)
    let requestedInvocationID = GatewayTestValues.invocationID(247)
    let cancellation = Task {
      try await client.cancelRun(
        GatewayCancelRunRequest(
          runID: requestedRunID,
          invocationID: requestedInvocationID
        )
      )
    }
    await transport.waitUntilCancelIsPending()
    await transport.resolveCancel(
      runID: GatewayTestValues.runID(248),
      invocationID: GatewayTestValues.invocationID(248)
    )

    do {
      _ = try await cancellation.value
      Issue.record("Expected mismatched cancellation response rejection.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .wrongRun)
    }
  }

  @Test
  func cancelResponseMustEchoRequestedInvocation() async throws {
    let transport = HostileLifecycleGatewayTransport()
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()
    let requestedRunID = GatewayTestValues.runID(253)
    let requestedInvocationID = GatewayTestValues.invocationID(253)
    let cancellation = Task {
      try await client.cancelRun(
        GatewayCancelRunRequest(
          runID: requestedRunID,
          invocationID: requestedInvocationID
        )
      )
    }
    await transport.waitUntilCancelIsPending()
    await transport.resolveCancel(
      runID: requestedRunID,
      invocationID: GatewayTestValues.invocationID(254)
    )

    do {
      _ = try await cancellation.value
      Issue.record("Expected mismatched cancellation invocation rejection.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .staleRunInvocation)
    }
  }

  @Test
  func cancelledCancellationCannotReturnWhenTransportIgnoresCancellation() async throws {
    let transport = HostileLifecycleGatewayTransport()
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()
    let runID = GatewayTestValues.runID(156)
    let invocationID = GatewayTestValues.invocationID(156)
    let cancellation = Task {
      try await client.cancelRun(
        GatewayCancelRunRequest(runID: runID, invocationID: invocationID)
      )
    }
    await transport.waitUntilCancelIsPending()
    cancellation.cancel()
    await transport.resolveCancel(runID: runID, invocationID: invocationID)

    do {
      _ = try await cancellation.value
      Issue.record("Expected cancellation from the cancellation request.")
    } catch is CancellationError {
      // Expected.
    }
  }

  @Test
  func gatewayRestartInvalidatesPendingCancellation() async throws {
    let transport = HostileLifecycleGatewayTransport()
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()
    let runID = GatewayTestValues.runID(251)
    let invocationID = GatewayTestValues.invocationID(251)
    let cancellation = Task {
      try await client.cancelRun(
        GatewayCancelRunRequest(runID: runID, invocationID: invocationID)
      )
    }
    await transport.waitUntilCancelIsPending()
    let reconnect = Task { try await client.connect() }
    await transport.waitUntilHandshakeIsPending(2)
    await transport.resolveHandshake(2, instanceSeed: 252)
    _ = try await reconnect.value
    await transport.resolveCancel(runID: runID, invocationID: invocationID)

    do {
      _ = try await cancellation.value
      Issue.record("Expected the pre-restart cancellation response to be rejected.")
    } catch let failure as GatewayFailure {
      expectSuperseded(failure)
    }
  }

  @Test
  func gatewayRestartRedactsPendingCancellationFailure() async throws {
    let transport = HostileLifecycleGatewayTransport()
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()
    let runID = GatewayTestValues.runID(157)
    let invocationID = GatewayTestValues.invocationID(157)
    let cancellation = Task {
      try await client.cancelRun(
        GatewayCancelRunRequest(runID: runID, invocationID: invocationID)
      )
    }
    await transport.waitUntilCancelIsPending()
    let reconnect = Task { try await client.connect() }
    await transport.waitUntilHandshakeIsPending(2)
    await transport.resolveHandshake(2, instanceSeed: 157)
    _ = try await reconnect.value
    await transport.failCancel(message: "secret stale cancellation failure")

    await expectSuperseded(cancellation)
  }

  @Test
  func gatewayRestartClosesPreviouslyReturnedEventStream() async throws {
    let transport = HostileLifecycleGatewayTransport()
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()
    let runID = GatewayTestValues.runID(249)
    let invocationID = GatewayTestValues.invocationID(249)
    let stream = try await client.eventRecords(for: runID, invocationID: invocationID)
    await transport.waitUntilStreamIsInstalled()
    let collector = Task {
      var records: [AgentEventRecord] = []
      for try await envelope in stream {
        records.append(envelope.record)
        if !records.isEmpty {
          break
        }
      }
      return records
    }
    let reconnect = Task { try await client.connect() }
    await transport.waitUntilHandshakeIsPending(2)
    await transport.resolveHandshake(2, instanceSeed: 250)
    _ = try await reconnect.value
    await transport.emit(
      GatewayTestValues.record(runID: runID, sequence: 1, event: .runStarted)
    )
    await transport.finishStream()

    do {
      _ = try await collector.value
      Issue.record("Expected the stale event stream to terminate with a fixed failure.")
    } catch let failure as GatewayFailure {
      expectSuperseded(failure)
    }
  }

  @Test
  func disconnectClosesPreviouslyReturnedEventStream() async throws {
    let transport = HostileLifecycleGatewayTransport()
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()
    let runID = GatewayTestValues.runID(158)
    let invocationID = GatewayTestValues.invocationID(158)
    let stream = try await client.eventRecords(for: runID, invocationID: invocationID)
    await transport.waitUntilStreamIsInstalled()
    let collector = Task {
      try await GatewayTestValues.collect(stream)
    }

    try await client.disconnect()
    await transport.emit(
      GatewayTestValues.record(runID: runID, sequence: 1, event: .runStarted)
    )
    await transport.finishStream()

    await expectSuperseded(collector)
  }

  @Test
  func gatewayRestartInvalidatesPendingEventStreamAcquisition() async throws {
    let transport = HostileLifecycleGatewayTransport(holdsEventRecordsResponse: true)
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()
    let streamRequest = Task {
      try await client.eventRecords(
        for: GatewayTestValues.runID(159),
        invocationID: GatewayTestValues.invocationID(159)
      )
    }
    await transport.waitUntilEventRecordsIsPending()

    let reconnect = Task { try await client.connect() }
    await transport.waitUntilHandshakeIsPending(2)
    await transport.resolveHandshake(2, instanceSeed: 159)
    _ = try await reconnect.value
    await transport.resolveEventRecords()

    await expectSuperseded(streamRequest)
    await transport.finishStream()
  }

  @Test
  func cancelledEventStreamAcquisitionCannotReturnDelayedStream() async throws {
    let transport = HostileLifecycleGatewayTransport(holdsEventRecordsResponse: true)
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()
    let streamRequest = Task {
      try await client.eventRecords(
        for: GatewayTestValues.runID(160),
        invocationID: GatewayTestValues.invocationID(160)
      )
    }
    await transport.waitUntilEventRecordsIsPending()
    streamRequest.cancel()
    await transport.resolveEventRecords()

    do {
      _ = try await streamRequest.value
      Issue.record("Expected cancellation from event stream acquisition.")
    } catch is CancellationError {
      // Expected.
    }
    await transport.finishStream()
  }

  @Test
  func gatewayRestartRedactsPendingEventStreamFailure() async throws {
    let transport = HostileLifecycleGatewayTransport(holdsEventRecordsResponse: true)
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()
    let streamRequest = Task {
      try await client.eventRecords(
        for: GatewayTestValues.runID(161),
        invocationID: GatewayTestValues.invocationID(161)
      )
    }
    await transport.waitUntilEventRecordsIsPending()

    let reconnect = Task { try await client.connect() }
    await transport.waitUntilHandshakeIsPending(2)
    await transport.resolveHandshake(2, instanceSeed: 161)
    _ = try await reconnect.value
    await transport.failEventRecords(message: "secret stale stream failure")

    await expectSuperseded(streamRequest)
  }

  private func handshakeResponse(
    sessionID: GatewaySessionID = GatewaySessionID(
      rawValue: GatewayTestValues.uuid(232)
    ),
    gatewayInstanceID: GatewayInstanceID = GatewayInstanceID(
      rawValue: GatewayTestValues.uuid(233)
    ),
    activeRun: GatewayRunSnapshot? = nil
  ) -> GatewayHandshakeResponse {
    GatewayHandshakeResponse(
      sessionID: sessionID,
      gatewayInstanceID: gatewayInstanceID,
      selectedVersion: .current,
      activeRun: activeRun
    )
  }

  private func expectSuperseded(_ failure: GatewayFailure) {
    #expect(
      failure
        == GatewayFailure(
          code: .supersededOperation,
          message: "The gateway client operation was superseded."
        )
    )
  }

  private func expectSuperseded<Value: Sendable>(
    _ task: Task<Value, any Error>
  ) async {
    do {
      _ = try await task.value
      Issue.record("Expected the stale operation to fail as superseded.")
    } catch let failure as GatewayFailure {
      expectSuperseded(failure)
    } catch {
      Issue.record("Expected the fixed superseded failure, received: \(error)")
    }
  }
}
