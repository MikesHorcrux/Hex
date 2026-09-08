import Foundation
import HexCore
import HexIPC
import Testing

@Suite("Resident control IPC")
struct ResidentControlIPCTests {
  @Test
  func controlStatusIsCodableInsideTheBoundedWireCodec() throws {
    let codec = GatewayWireCodec(configuration: .standard)
    let lease = GatewayTransportConnectionLease(rawValue: GatewayTestValues.uuid(221))
    let sessionID = GatewaySessionID(rawValue: GatewayTestValues.uuid(222))
    let envelope = GatewayXPCRequestEnvelope(
      operation: .pauseHeartbeats,
      lease: lease,
      sessionID: sessionID,
      body: Data()
    )

    #expect(try codec.roundTrip(GatewayResidentStatus.unavailable) == .unavailable)
    #expect(try codec.roundTrip(GatewayResidentStatus.idle) == .idle)
    #expect(try codec.roundTrip(GatewayResidentStatus.active) == .active)
    #expect(try codec.roundTrip(GatewayResidentStatus.paused) == .paused)
    let encodedEnvelope = try codec.encode(envelope)
    #expect(encodedEnvelope.count <= GatewayConfiguration.standard.maximumWireBytes)
    #expect(try codec.roundTrip(envelope) == envelope)
  }

  @Test
  func missingResidentHandlersFailClosedWithoutChangingTheAuthenticatedSession() async throws {
    let gateway = HexGatewayService(driver: ImmediateGatewayRunDriver())
    let exportedService = HexGatewayXPCService(service: gateway)
    let codec = GatewayWireCodec(configuration: .standard)
    let lease = GatewayTransportConnectionLease(rawValue: GatewayTestValues.uuid(223))
    let handshakeResponse = try await sendHandshake(
      lease: lease,
      request: GatewayTestValues.handshakeRequest(224),
      service: exportedService,
      codec: codec
    )

    let statusResponse = try await sendControl(
      operation: .status,
      lease: lease,
      sessionID: handshakeResponse.sessionID,
      service: exportedService,
      codec: codec
    )
    #expect(statusResponse.failure == nil)
    #expect(
      try codec.decode(
        GatewayResidentStatus.self,
        from: try #require(statusResponse.body)
      ) == .unavailable
    )

    let pauseResponse = try await sendControl(
      operation: .pauseHeartbeats,
      lease: lease,
      sessionID: handshakeResponse.sessionID,
      service: exportedService,
      codec: codec
    )
    #expect(pauseResponse.failure?.code == .transportUnavailable)

    let staleResponse = try await sendControl(
      operation: .resumeHeartbeats,
      lease: lease,
      sessionID: GatewaySessionID(rawValue: GatewayTestValues.uuid(225)),
      service: exportedService,
      codec: codec
    )
    #expect(staleResponse.failure?.code == .staleSession)
  }

  @Test
  func injectedResidentHandlersReturnEachScopedHeartbeatState() async throws {
    let gateway = HexGatewayService(driver: ImmediateGatewayRunDriver())
    let handlers = HexGatewayResidentControlHandlers(
      status: { () async throws -> GatewayResidentStatus in .active },
      pauseHeartbeats: { () async throws -> GatewayResidentStatus in .paused },
      resumeHeartbeats: { () async throws -> GatewayResidentStatus in .idle }
    )
    let exportedService = HexGatewayXPCService(
      service: gateway,
      residentControlHandlers: handlers
    )
    let codec = GatewayWireCodec(configuration: .standard)
    let lease = GatewayTransportConnectionLease(rawValue: GatewayTestValues.uuid(229))
    let handshakeResponse = try await sendHandshake(
      lease: lease,
      request: GatewayTestValues.handshakeRequest(230),
      service: exportedService,
      codec: codec
    )

    let status = try await sendControl(
      operation: .status,
      lease: lease,
      sessionID: handshakeResponse.sessionID,
      service: exportedService,
      codec: codec
    )
    let paused = try await sendControl(
      operation: .pauseHeartbeats,
      lease: lease,
      sessionID: handshakeResponse.sessionID,
      service: exportedService,
      codec: codec
    )
    let resumed = try await sendControl(
      operation: .resumeHeartbeats,
      lease: lease,
      sessionID: handshakeResponse.sessionID,
      service: exportedService,
      codec: codec
    )

    #expect(try controlStatus(from: status, codec: codec) == .active)
    #expect(try controlStatus(from: paused, codec: codec) == .paused)
    #expect(try controlStatus(from: resumed, codec: codec) == .idle)
  }

  @Test
  func staleResidentStatusCannotCommitAfterAConnectionReplacement() async throws {
    let transport = DelayedResidentControlTransport()
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()

    let statusTask = Task {
      try await client.status()
    }
    await transport.waitUntilStatusEntered()

    _ = try await client.connect()
    await transport.releaseStatus()

    do {
      _ = try await statusTask.value
      Issue.record("Expected a resident status response from the old generation to be rejected.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .supersededOperation)
    }
  }

  private actor DelayedResidentControlTransport: HexGatewayTransport,
    HexGatewayResidentControlTransport
  {
    private var handshakeResponses: [GatewayHandshakeResponse] = [
      GatewayHandshakeResponse(
        sessionID: GatewaySessionID(rawValue: GatewayTestValues.uuid(226)),
        gatewayInstanceID: GatewayInstanceID(rawValue: GatewayTestValues.uuid(227)),
        selectedVersion: .current,
        activeRun: nil
      ),
      GatewayHandshakeResponse(
        sessionID: GatewaySessionID(rawValue: GatewayTestValues.uuid(228)),
        gatewayInstanceID: GatewayInstanceID(rawValue: GatewayTestValues.uuid(227)),
        selectedVersion: .current,
        activeRun: nil
      ),
    ]
    private var connectedLease: GatewayTransportConnectionLease?
    private var statusEntered = false
    private var statusReleased = false
    private var statusEntryContinuation: CheckedContinuation<Void, Never>?
    private var statusReleaseContinuation: CheckedContinuation<Void, Never>?

    func handshake(
      _ request: GatewayHandshakeRequest,
      lease: GatewayTransportConnectionLease
    ) throws -> GatewayHandshakeResponse {
      guard let response = handshakeResponses.first else {
        throw GatewayFailure(
          code: .transportUnavailable,
          message: "No scripted handshake response remains."
        )
      }
      handshakeResponses.removeFirst()
      connectedLease = lease
      return response
    }

    func startRun(
      _ request: GatewayStartRunRequest,
      lease: GatewayTransportConnectionLease
    ) throws -> GatewayStartRunResponse {
      throw GatewayFailure(code: .transportUnavailable, message: "Not used by this test.")
    }

    func cancelRun(
      _ request: GatewayCancelRunRequest,
      lease: GatewayTransportConnectionLease
    ) throws -> GatewayCancelRunResponse {
      throw GatewayFailure(code: .transportUnavailable, message: "Not used by this test.")
    }

    func eventRecords(
      after cursor: GatewayEventCursor,
      lease: GatewayTransportConnectionLease
    ) throws -> AsyncThrowingStream<GatewayEventEnvelope, any Error> {
      AsyncThrowingStream { continuation in
        continuation.finish()
      }
    }

    func disconnect(lease: GatewayTransportConnectionLease) {
      guard connectedLease == lease else {
        return
      }
      connectedLease = nil
    }

    func status(
      lease: GatewayTransportConnectionLease
    ) async throws -> GatewayResidentStatus {
      guard connectedLease == lease else {
        throw GatewayFailure(code: .notConnected, message: "The test transport is disconnected.")
      }
      statusEntered = true
      statusEntryContinuation?.resume()
      statusEntryContinuation = nil
      if !statusReleased {
        await withCheckedContinuation { continuation in
          statusReleaseContinuation = continuation
        }
      }
      return .active
    }

    func pauseHeartbeats(
      lease: GatewayTransportConnectionLease
    ) async throws -> GatewayResidentStatus {
      throw GatewayFailure(code: .transportUnavailable, message: "Not used by this test.")
    }

    func resumeHeartbeats(
      lease: GatewayTransportConnectionLease
    ) async throws -> GatewayResidentStatus {
      throw GatewayFailure(code: .transportUnavailable, message: "Not used by this test.")
    }

    func waitUntilStatusEntered() async {
      guard !statusEntered else {
        return
      }
      await withCheckedContinuation { continuation in
        statusEntryContinuation = continuation
      }
    }

    func releaseStatus() {
      statusReleased = true
      statusReleaseContinuation?.resume()
      statusReleaseContinuation = nil
    }
  }

  private actor ResponseStore {
    private var response: Data?

    func set(_ response: Data) {
      self.response = response
    }

    func wait() async -> Data {
      while response == nil {
        await Task.yield()
      }
      return response ?? Data()
    }
  }

  private func sendHandshake(
    lease: GatewayTransportConnectionLease,
    request: GatewayHandshakeRequest,
    service: HexGatewayXPCService,
    codec: GatewayWireCodec
  ) async throws -> GatewayHandshakeResponse {
    let envelope = try codec.encode(
      GatewayXPCRequestEnvelope(
        operation: .handshake,
        lease: lease,
        body: try codec.encode(request)
      )
    )
    let rawResponse = try await sendRequest(envelope, to: service)
    let response = try codec.decode(GatewayXPCResponseEnvelope.self, from: rawResponse).validated()
    if let failure = response.failure {
      throw failure
    }
    return try codec.decode(GatewayHandshakeResponse.self, from: try #require(response.body))
  }

  private func sendControl(
    operation: GatewayXPCOperation,
    lease: GatewayTransportConnectionLease,
    sessionID: GatewaySessionID,
    service: HexGatewayXPCService,
    codec: GatewayWireCodec
  ) async throws -> GatewayXPCResponseEnvelope {
    let envelope = try codec.encode(
      GatewayXPCRequestEnvelope(
        operation: operation,
        lease: lease,
        sessionID: sessionID,
        body: Data()
      )
    )
    let rawResponse = try await sendRequest(envelope, to: service)
    return try codec.decode(GatewayXPCResponseEnvelope.self, from: rawResponse).validated()
  }

  private func sendRequest(
    _ envelope: Data,
    to service: HexGatewayXPCService
  ) async throws -> Data {
    let store = ResponseStore()
    service.request(envelope) { response in
      Task {
        await store.set(response)
      }
    }
    return await store.wait()
  }

  private func controlStatus(
    from response: GatewayXPCResponseEnvelope,
    codec: GatewayWireCodec
  ) throws -> GatewayResidentStatus {
    if let failure = response.failure {
      throw failure
    }
    return try codec.decode(GatewayResidentStatus.self, from: try #require(response.body))
  }
}
