import Foundation
import HexCore
import HexIPC
import Testing

@Suite("Screen-control permission IPC")
struct ScreenControlPermissionIPCTests {
  @Test
  func statusKeepsTheTwoRequiredMacPermissionsSeparate() {
    let partial = GatewayScreenControlPermissionStatus(
      accessibilityGranted: true,
      screenRecordingGranted: false
    )
    let granted = GatewayScreenControlPermissionStatus(
      accessibilityGranted: true,
      screenRecordingGranted: true
    )

    #expect(!partial.isGranted)
    #expect(granted.isGranted)
  }

  @Test
  func authenticatedStatusAndRequestReturnTheInjectedAsyncState() async throws {
    let calls = PermissionCallStore()
    let statusValue = GatewayScreenControlPermissionStatus(
      accessibilityGranted: false,
      screenRecordingGranted: true
    )
    let requestValue = GatewayScreenControlPermissionStatus(
      accessibilityGranted: true,
      screenRecordingGranted: true
    )
    let service = HexGatewayXPCService(
      service: HexGatewayService(driver: ImmediateGatewayRunDriver()),
      screenControlPermissionHandlers: HexGatewayScreenControlPermissionHandlers(
        status: {
          await calls.recordStatus()
          await Task.yield()
          return statusValue
        },
        request: {
          await calls.recordRequest()
          await Task.yield()
          return requestValue
        }
      )
    )
    let codec = GatewayWireCodec(configuration: .standard)
    let lease = GatewayTransportConnectionLease(rawValue: GatewayTestValues.uuid(221))
    let sessionID = try await handshake(
      lease: lease,
      service: service,
      codec: codec
    )

    let status = try await sendPermissionOperation(
      .screenControlPermissionStatus,
      lease: lease,
      sessionID: sessionID,
      service: service,
      codec: codec
    )
    let request = try await sendPermissionOperation(
      .requestScreenControlPermission,
      lease: lease,
      sessionID: sessionID,
      service: service,
      codec: codec
    )

    #expect(try permissionStatus(from: status, codec: codec) == statusValue)
    #expect(try permissionStatus(from: request, codec: codec) == requestValue)
    #expect(await calls.statusCount == 1)
    #expect(await calls.requestCount == 1)
  }

  @Test
  func operationsRejectMissingAndMismatchedAuthenticatedSessionsBeforeDispatch() async throws {
    let calls = PermissionCallStore()
    let service = HexGatewayXPCService(
      service: HexGatewayService(driver: ImmediateGatewayRunDriver()),
      screenControlPermissionHandlers: HexGatewayScreenControlPermissionHandlers(
        status: {
          await calls.recordStatus()
          return GatewayScreenControlPermissionStatus(
            accessibilityGranted: false,
            screenRecordingGranted: false
          )
        },
        request: {
          await calls.recordRequest()
          return GatewayScreenControlPermissionStatus(
            accessibilityGranted: false,
            screenRecordingGranted: false
          )
        }
      )
    )
    let codec = GatewayWireCodec(configuration: .standard)
    let lease = GatewayTransportConnectionLease(rawValue: GatewayTestValues.uuid(222))

    let disconnectedStatus = try await sendPermissionOperation(
      .screenControlPermissionStatus,
      lease: lease,
      sessionID: GatewaySessionID(rawValue: GatewayTestValues.uuid(223)),
      service: service,
      codec: codec
    )
    let disconnectedRequest = try await sendPermissionOperation(
      .requestScreenControlPermission,
      lease: lease,
      sessionID: GatewaySessionID(rawValue: GatewayTestValues.uuid(223)),
      service: service,
      codec: codec
    )
    #expect(disconnectedStatus.failure?.code == .notConnected)
    #expect(disconnectedRequest.failure?.code == .notConnected)

    _ = try await handshake(lease: lease, service: service, codec: codec)
    let staleStatus = try await sendPermissionOperation(
      .screenControlPermissionStatus,
      lease: lease,
      sessionID: GatewaySessionID(rawValue: GatewayTestValues.uuid(224)),
      service: service,
      codec: codec
    )
    let staleRequest = try await sendPermissionOperation(
      .requestScreenControlPermission,
      lease: lease,
      sessionID: GatewaySessionID(rawValue: GatewayTestValues.uuid(224)),
      service: service,
      codec: codec
    )
    #expect(staleStatus.failure?.code == .staleSession)
    #expect(staleRequest.failure?.code == .staleSession)
    #expect(await calls.statusCount == 0)
    #expect(await calls.requestCount == 0)
  }

  @Test
  func missingPermissionHandlersFailClosed() async throws {
    let service = HexGatewayXPCService(
      service: HexGatewayService(driver: ImmediateGatewayRunDriver())
    )
    let codec = GatewayWireCodec(configuration: .standard)
    let lease = GatewayTransportConnectionLease(rawValue: GatewayTestValues.uuid(225))
    let sessionID = try await handshake(lease: lease, service: service, codec: codec)

    let status = try await sendPermissionOperation(
      .screenControlPermissionStatus,
      lease: lease,
      sessionID: sessionID,
      service: service,
      codec: codec
    )
    let request = try await sendPermissionOperation(
      .requestScreenControlPermission,
      lease: lease,
      sessionID: sessionID,
      service: service,
      codec: codec
    )

    #expect(status.failure?.code == .transportUnavailable)
    #expect(request.failure?.code == .transportUnavailable)
  }

  private actor PermissionCallStore {
    private(set) var statusCount = 0
    private(set) var requestCount = 0

    func recordStatus() {
      statusCount += 1
    }

    func recordRequest() {
      requestCount += 1
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

  private func handshake(
    lease: GatewayTransportConnectionLease,
    service: HexGatewayXPCService,
    codec: GatewayWireCodec
  ) async throws -> GatewaySessionID {
    let envelope = try codec.encode(
      GatewayXPCRequestEnvelope(
        operation: .handshake,
        lease: lease,
        body: try codec.encode(GatewayTestValues.handshakeRequest(226))
      )
    )
    let response = try codec.decode(
      GatewayXPCResponseEnvelope.self,
      from: await send(envelope, to: service)
    ).validated()
    if let failure = response.failure {
      throw failure
    }
    return try codec.decode(
      GatewayHandshakeResponse.self,
      from: try #require(response.body)
    ).sessionID
  }

  private func sendPermissionOperation(
    _ operation: GatewayXPCOperation,
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
    return try codec.decode(
      GatewayXPCResponseEnvelope.self,
      from: await send(envelope, to: service)
    ).validated()
  }

  private func send(
    _ envelope: Data,
    to service: HexGatewayXPCService
  ) async -> Data {
    let store = ResponseStore()
    service.request(envelope) { response in
      Task {
        await store.set(response)
      }
    }
    return await store.wait()
  }

  private func permissionStatus(
    from response: GatewayXPCResponseEnvelope,
    codec: GatewayWireCodec
  ) throws -> GatewayScreenControlPermissionStatus {
    if let failure = response.failure {
      throw failure
    }
    return try codec.decode(
      GatewayScreenControlPermissionStatus.self,
      from: try #require(response.body)
    )
  }
}
