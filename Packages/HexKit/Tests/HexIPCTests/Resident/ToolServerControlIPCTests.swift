@preconcurrency import Foundation
import HexCore
import Synchronization
import Testing

@testable import HexIPC

@Suite("Tool server health and refresh IPC")
struct ToolServerControlIPCTests {
  @Test(arguments: [false, true])
  func clientListsAndRefreshesOnlyTheRequestedServer(useXPC: Bool) async throws {
    let state = HandlerState()
    let gateway = HexGatewayService(driver: ImmediateGatewayRunDriver())
    let client = makeClient(gateway, handlers: handlers(state), useXPC: useXPC)
    _ = try await client.connect()
    #expect(try await client.toolServerHealth() == Self.health)
    #expect(try await client.refreshToolServer(Self.request) == Self.ready)
    #expect(await state.calls == ["list", "playwright"])
    #expect(await gateway.runs.isEmpty)
    try await client.disconnect()
    try await gateway.shutdown()
  }

  @Test(arguments: [false, true])
  func malformedRequestAndMismatchedReplyFailClosed(useXPC: Bool) async throws {
    let state = HandlerState()
    let gateway = HexGatewayService(driver: ImmediateGatewayRunDriver())
    let client = makeClient(
      gateway,
      handlers: HexGatewayToolServerControlHandlers(refresh: { request in
        await state.record(request.serverID)
        return GatewayToolServerStatus(serverID: "other", state: .ready, availableToolCount: 1)
      }), useXPC: useXPC)
    _ = try await client.connect()
    await expectFailure(.malformedPayload) {
      _ = try await client.refreshToolServer(GatewayToolServerRequest(serverID: "../server"))
    }
    #expect(await state.calls.isEmpty)
    await expectFailure(.malformedPayload) {
      _ = try await client.refreshToolServer(Self.request)
    }
    #expect(await state.calls == ["playwright"])
    #expect(await gateway.toolMaintenance == nil)
    try await client.disconnect()
  }

  @Test(arguments: [false, true])
  func missingHandlersAreUnavailableAndNeverStartWork(useXPC: Bool) async throws {
    let gateway = HexGatewayService(driver: ImmediateGatewayRunDriver())
    let client = makeClient(gateway, handlers: .unavailable, useXPC: useXPC)
    _ = try await client.connect()
    await expectFailure(.transportUnavailable) { _ = try await client.toolServerHealth() }
    _ = try await client.connect()
    await expectFailure(.transportUnavailable) {
      _ = try await client.refreshToolServer(Self.request)
    }
    #expect(await gateway.runs.isEmpty)
    #expect(await gateway.toolMaintenance == nil)
    try await client.disconnect()
  }

  @Test(arguments: [false, true])
  func invalidHealthResponseIsNotDisplayedAsReady(useXPC: Bool) async throws {
    let gateway = HexGatewayService(driver: ImmediateGatewayRunDriver())
    let client = makeClient(
      gateway,
      handlers: HexGatewayToolServerControlHandlers(list: {
        GatewayToolServerHealth(servers: [Self.ready, Self.ready])
      }), useXPC: useXPC)
    _ = try await client.connect()
    await expectFailure(.malformedPayload) { _ = try await client.toolServerHealth() }
    try await client.disconnect()
  }

  @Test(arguments: [false, true])
  func staleLeaseCannotDispatchRefresh(useXPC: Bool) async throws {
    let state = HandlerState()
    let gateway = HexGatewayService(driver: ImmediateGatewayRunDriver())
    let transport = makeTransport(gateway, handlers: handlers(state), useXPC: useXPC)
    let oldLease = GatewayTransportConnectionLease()
    let currentLease = GatewayTransportConnectionLease()
    _ = try await transport.handshake(GatewayTestValues.handshakeRequest(), lease: oldLease)
    _ = try await transport.handshake(GatewayTestValues.handshakeRequest(11), lease: currentLease)
    let controls = try #require(transport as? any HexGatewayToolServerControlTransport)
    do {
      _ = try await controls.refreshToolServer(Self.request, lease: oldLease)
      Issue.record("A replaced connection must not refresh a tool server.")
    } catch let failure as GatewayFailure {
      #expect(
        [GatewayFailureCode.notConnected, .staleSession, .supersededOperation].contains(
          failure.code))
    }
    #expect(await state.calls.isEmpty)
    try await transport.disconnect(lease: currentLease)
  }

  @Test(arguments: [false, true])
  func replyFromDisconnectedGenerationCannotCommit(useXPC: Bool) async throws {
    let gate = Gate()
    let gateway = HexGatewayService(driver: ImmediateGatewayRunDriver())
    let client = makeClient(
      gateway,
      handlers: HexGatewayToolServerControlHandlers(list: {
        await gate.enter()
        return Self.health
      }), useXPC: useXPC)
    _ = try await client.connect()
    let pending = Task { try await client.toolServerHealth() }
    try await waitUntil { await gate.entered }
    try await client.disconnect()
    await gate.release()
    do {
      _ = try await pending.value
      Issue.record("A stale status result must not commit after disconnect.")
    } catch let failure as GatewayFailure {
      #expect(
        [GatewayFailureCode.notConnected, .disconnected, .staleSession, .supersededOperation]
          .contains(failure.code))
    }
  }

  @Test(arguments: [false, true])
  func olderPeerIsRejectedBeforeControlsDispatch(useXPC: Bool) async throws {
    let state = HandlerState()
    let gateway = HexGatewayService(driver: ImmediateGatewayRunDriver())
    let transport = makeTransport(gateway, handlers: handlers(state), useXPC: useXPC)
    let oldVersion = GatewayProtocolVersion(major: 1, minor: 12)
    await expectFailure(.incompatibleProtocolVersion) {
      _ = try await transport.handshake(
        GatewayHandshakeRequest(
          clientID: GatewayClientID(), minimumVersion: oldVersion, maximumVersion: oldVersion),
        lease: GatewayTransportConnectionLease())
    }
    #expect(await state.calls.isEmpty)
  }

  @Test
  func validatesBoundedCategorizedMetadataWithoutRawDiagnostics() throws {
    let codec = GatewayWireCodec(configuration: .standard)
    #expect(try codec.roundTrip(Self.health).validated() == Self.health)
    for id in ["", "UPPER", "white space", "secret/path", "é", String(repeating: "a", count: 33)] {
      #expect(throws: GatewayFailure.self) {
        try GatewayToolServerRequest(serverID: id).validated()
      }
    }
    let invalid = [
      GatewayToolServerStatus(serverID: "a", state: .ready),
      GatewayToolServerStatus(serverID: "a", state: .ready, availableToolCount: -1),
      GatewayToolServerStatus(serverID: "a", state: .ready, availableToolCount: 4097),
      GatewayToolServerStatus(
        serverID: "a", state: .ready, failure: .serverRejected, availableToolCount: 1),
      GatewayToolServerStatus(serverID: "a", state: .connecting, failure: .connectionFailed),
      GatewayToolServerStatus(serverID: "a", state: .unavailable, availableToolCount: 0),
    ]
    for status in invalid { #expect(throws: GatewayFailure.self) { try status.validated() } }
    #expect(throws: GatewayFailure.self) {
      try GatewayToolServerHealth(
        servers: (0..<17).map {
          GatewayToolServerStatus(serverID: "server_\($0)", state: .disconnected)
        }
      ).validated()
    }
    #expect(
      try GatewayToolServerStatus(serverID: "a", state: .ready, availableToolCount: 0).validated()
        .availableToolCount == 0)
    #expect(
      try GatewayToolServerStatus(serverID: "a", state: .ready, availableToolCount: 4096)
        .validated().availableToolCount == 4096)
  }

  @Test
  func foundationXPCSerializesHealthAndCorrelatedRefresh() async throws {
    let state = HandlerState()
    let gateway = HexGatewayService(driver: ImmediateGatewayRunDriver())
    let exported = HexGatewayXPCService(
      service: gateway, toolServerControlHandlers: handlers(state))
    let delegate = HexGatewayXPCListenerDelegate(serviceFactory: { exported })
    defer { withExtendedLifetime(delegate) {} }
    let listener = NSXPCListener.anonymous()
    listener.delegate = delegate
    listener.resume()
    defer { listener.invalidate() }
    let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
    connection.remoteObjectInterface = HexGatewayXPCService.interface()
    connection.activate()
    defer {
      connection.invalidate()
      exported.invalidate()
    }
    let codec = GatewayWireCodec(configuration: .standard)
    let lease = GatewayTransportConnectionLease()
    let handshakeData = try await send(
      codec.encode(
        GatewayXPCRequestEnvelope(
          operation: .handshake, lease: lease,
          body: codec.encode(GatewayTestValues.handshakeRequest()))),
      over: connection)
    let handshakeEnvelope = try codec.decode(GatewayXPCResponseEnvelope.self, from: handshakeData)
      .validated()
    #expect(handshakeEnvelope.failure == nil)
    let handshake = try codec.decode(
      GatewayHandshakeResponse.self, from: #require(handshakeEnvelope.body))
    for operation: GatewayXPCOperation in [.toolServerHealth, .refreshToolServer] {
      let body = operation == .refreshToolServer ? try codec.encode(Self.request) : Data()
      let data = try await send(
        codec.encode(
          GatewayXPCRequestEnvelope(
            operation: operation, lease: lease, sessionID: handshake.sessionID, body: body)),
        over: connection)
      let response = try codec.decode(GatewayXPCResponseEnvelope.self, from: data).validated()
      #expect(response.operation == operation)
      #expect(response.failure == nil)
      if operation == .toolServerHealth {
        #expect(
          try codec.decode(GatewayToolServerHealth.self, from: #require(response.body)).validated()
            == Self.health)
      } else {
        #expect(
          try codec.decode(GatewayToolServerStatus.self, from: #require(response.body)).validated(
            for: Self.request) == Self.ready)
      }
    }
    #expect(await state.calls == ["list", "playwright"])
    try await gateway.shutdown()
  }

  private static let request = GatewayToolServerRequest(serverID: "playwright")
  private static let ready = GatewayToolServerStatus(
    serverID: "playwright", state: .ready, availableToolCount: 23)
  private static let health = GatewayToolServerHealth(servers: [
    ready,
    GatewayToolServerStatus(serverID: "peekaboo", state: .unavailable, failure: .componentMissing),
  ])

  private func handlers(_ state: HandlerState) -> HexGatewayToolServerControlHandlers {
    HexGatewayToolServerControlHandlers(
      list: {
        await state.record("list")
        return Self.health
      },
      refresh: { request in
        await state.record(request.serverID)
        return Self.ready
      })
  }

  private func makeClient(
    _ gateway: HexGatewayService, handlers: HexGatewayToolServerControlHandlers, useXPC: Bool
  ) -> HexGatewayClient {
    HexGatewayClient(transport: makeTransport(gateway, handlers: handlers, useXPC: useXPC))
  }

  private func makeTransport(
    _ gateway: HexGatewayService, handlers: HexGatewayToolServerControlHandlers, useXPC: Bool
  ) -> any HexGatewayTransport {
    if useXPC {
      return XPCGatewayTransport(
        connectionFactory: ConnectionFactory(connection: Connection(gateway, handlers: handlers)))
    }
    return InProcessHexGatewayTransport(service: gateway, toolServerControlHandlers: handlers)
  }

  private func expectFailure(_ code: GatewayFailureCode, operation: () async throws -> Void) async {
    do {
      try await operation()
      Issue.record("Expected \(code).")
    } catch let failure as GatewayFailure { #expect(failure.code == code) } catch {
      Issue.record("Unexpected failure: \(error)")
    }
  }

  private func waitUntil(_ predicate: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !(await predicate()) {
      guard ContinuousClock.now < deadline else { throw FixtureError.timedOut }
      try await Task.sleep(for: .milliseconds(1))
    }
  }

  private func send(_ data: Data, over connection: NSXPCConnection) async throws -> Data {
    let result = Mutex<Result<Data, any Error>?>(nil)
    guard
      let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
        result.withLock { if $0 == nil { $0 = .failure(error) } }
      }) as? HexGatewayXPCServiceProtocol
    else { throw FixtureError.proxyUnavailable }
    proxy.request(data) { data in result.withLock { if $0 == nil { $0 = .success(data) } } }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while true {
      if let value = result.withLock({ $0 }) { return try value.get() }
      guard ContinuousClock.now < deadline else { throw FixtureError.timedOut }
      try await Task.sleep(for: .milliseconds(1))
    }
  }

  private actor HandlerState {
    var calls: [String] = []
    func record(_ call: String) { calls.append(call) }
  }

  private actor Gate {
    var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    func enter() async {
      entered = true
      await withCheckedContinuation { waiter = $0 }
    }
    func release() {
      waiter?.resume()
      waiter = nil
    }
  }

  private enum FixtureError: Error { case timedOut, proxyUnavailable }

  private actor Connection: HexGatewayXPCConnection {
    let exported: HexGatewayXPCService
    init(_ gateway: HexGatewayService, handlers: HexGatewayToolServerControlHandlers) {
      exported = HexGatewayXPCService(service: gateway, toolServerControlHandlers: handlers)
    }
    func request(_ envelope: Data) async throws -> Data {
      let result = Mutex<Data?>(nil)
      exported.request(envelope) { data in result.withLock { $0 = data } }
      let deadline = ContinuousClock.now.advanced(by: .seconds(2))
      while true {
        if let data = result.withLock({ $0 }) { return data }
        guard ContinuousClock.now < deadline else { throw FixtureError.timedOut }
        try await Task.sleep(for: .milliseconds(1))
      }
    }
    func subscribe(_ envelope: Data, bufferCapacity: Int) async throws
      -> GatewayXPCEventSubscription
    {
      throw GatewayFailure(code: .transportUnavailable, message: "Not used.")
    }
    func cancelSubscription(_ envelope: Data) async {}
    func invalidate() async { exported.invalidate() }
  }

  private struct ConnectionFactory: HexGatewayXPCConnectionFactory {
    let connection: Connection
    func makeConnection() -> any HexGatewayXPCConnection { connection }
  }
}
