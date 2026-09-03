import Foundation
import HexCore
import HexIPC
import Testing

@Suite("Accessibility permission IPC")
struct AccessibilityPermissionIPCTests {
  @Test
  func authenticatedStatusAndRequestReturnTheInjectedAsyncState() async throws {
    let calls = PermissionCallStore()
    let service = HexGatewayXPCService(
      service: HexGatewayService(driver: ImmediateGatewayRunDriver()),
      accessibilityPermissionHandlers: HexGatewayAccessibilityPermissionHandlers(
        status: {
          await calls.recordStatus()
          await Task.yield()
          return .notTrusted
        },
        request: {
          await calls.recordRequest()
          await Task.yield()
          return .notTrusted
        }
      )
    )
    let codec = GatewayWireCodec(configuration: .standard)
    let lease = GatewayTransportConnectionLease(rawValue: GatewayTestValues.uuid(211))
    let sessionID = try await handshake(
      lease: lease,
      service: service,
      codec: codec
    )

    let status = try await sendPermissionOperation(
      .accessibilityPermissionStatus,
      lease: lease,
      sessionID: sessionID,
      service: service,
      codec: codec
    )
    let request = try await sendPermissionOperation(
      .requestAccessibilityPermission,
      lease: lease,
      sessionID: sessionID,
      service: service,
      codec: codec
    )

    #expect(try permissionStatus(from: status, codec: codec) == .notTrusted)
    #expect(try permissionStatus(from: request, codec: codec) == .notTrusted)
    #expect(await calls.statusCount == 1)
    #expect(await calls.requestCount == 1)
  }

  @Test
  func requestRejectsMissingAndMismatchedAuthenticatedSessionsBeforeDispatch() async throws {
    let calls = PermissionCallStore()
    let service = HexGatewayXPCService(
      service: HexGatewayService(driver: ImmediateGatewayRunDriver()),
      accessibilityPermissionHandlers: HexGatewayAccessibilityPermissionHandlers(
        request: {
          await calls.recordRequest()
          return .notTrusted
        }
      )
    )
    let codec = GatewayWireCodec(configuration: .standard)
    let lease = GatewayTransportConnectionLease(rawValue: GatewayTestValues.uuid(212))

    let disconnected = try await sendPermissionOperation(
      .requestAccessibilityPermission,
      lease: lease,
      sessionID: GatewaySessionID(rawValue: GatewayTestValues.uuid(213)),
      service: service,
      codec: codec
    )
    #expect(disconnected.failure?.code == .notConnected)

    _ = try await handshake(lease: lease, service: service, codec: codec)
    let stale = try await sendPermissionOperation(
      .requestAccessibilityPermission,
      lease: lease,
      sessionID: GatewaySessionID(rawValue: GatewayTestValues.uuid(214)),
      service: service,
      codec: codec
    )
    #expect(stale.failure?.code == .staleSession)
    #expect(await calls.requestCount == 0)
  }

  @Test
  func missingPermissionHandlersFailClosed() async throws {
    let service = HexGatewayXPCService(
      service: HexGatewayService(driver: ImmediateGatewayRunDriver())
    )
    let codec = GatewayWireCodec(configuration: .standard)
    let lease = GatewayTransportConnectionLease(rawValue: GatewayTestValues.uuid(215))
    let sessionID = try await handshake(lease: lease, service: service, codec: codec)

    let status = try await sendPermissionOperation(
      .accessibilityPermissionStatus,
      lease: lease,
      sessionID: sessionID,
      service: service,
      codec: codec
    )
    let request = try await sendPermissionOperation(
      .requestAccessibilityPermission,
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
        body: try codec.encode(GatewayTestValues.handshakeRequest(216))
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
  ) throws -> GatewayAccessibilityPermissionStatus {
    if let failure = response.failure {
      throw failure
    }
    return try codec.decode(
      GatewayAccessibilityPermissionStatus.self,
      from: try #require(response.body)
    )
  }
}
