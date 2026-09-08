import Foundation
import HexCore
import HexIPC
import Testing

@testable import Hex

@Suite("Live agent client connection reuse")
struct HexLiveAgentClientTests {
  @Test
  func scheduledHistoryUsesTheLiveClientProtocolWitnessWithoutStartingWork() async throws {
    let transport = CountingTransport()
    let client = HexLiveAgentClient(
      configuration: HexDeveloperConfiguration(environment: [:]),
      route: .residentXPC(machServiceName: "com.example.hex.test"),
      initialGatewayAdapter: HexGatewayClientAdapter(
        client: HexGatewayClient(transport: transport),
        authorizationTransport: NoopAuthorizationTransport()))
    let service: any HexHeartbeatManaging = client
    let request = GatewayHeartbeatRunListRequest(scheduleID: UUID(), limit: 7)

    let page = try await service.listHeartbeatRuns(request)
    #expect(page.runs.count == 1)
    #expect(page.runs.first?.scheduleID == request.scheduleID)
    #expect(page.runs.first?.scheduleName == "Saved scheduled read")
    #expect(await transport.historyRequests == [request])
    #expect(await transport.handshakeCallCount == 1)
    #expect(await transport.startCallCount == 0)
  }

  @Test
  func scheduledHistoryConnectionFailureRequiresAFreshHandshake() async throws {
    let transport = CountingTransport(historyFailure: .staleSession)
    let client = HexLiveAgentClient(
      configuration: HexDeveloperConfiguration(environment: [:]),
      route: .residentXPC(machServiceName: "com.example.hex.test"),
      initialGatewayAdapter: HexGatewayClientAdapter(
        client: HexGatewayClient(transport: transport),
        authorizationTransport: NoopAuthorizationTransport()))
    let service: any HexHeartbeatManaging = client
    do {
      _ = try await service.listHeartbeatRuns(GatewayHeartbeatRunListRequest())
      Issue.record("A stale history connection must not return a page.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .staleSession)
    }
    _ = try await client.connect()
    #expect(await transport.handshakeCallCount == 2)
    #expect(await transport.historyRequests.count == 1)
    #expect(await transport.startCallCount == 0)
  }

  @Test
  func rejectsAStaleOrUnidentifiedHelperBeforeAnyRunCanStart() async throws {
    let expected = UUID()
    for received in [UUID?.none, UUID?.some(UUID())] {
      let transport = CountingTransport(executableID: received)
      let adapter = HexGatewayClientAdapter(
        client: HexGatewayClient(transport: transport),
        authorizationTransport: NoopAuthorizationTransport(), expectedExecutableID: expected)
      do {
        _ = try await adapter.connect()
        Issue.record("A stale or unknown helper build must not be accepted.")
      } catch let failure as GatewayFailure {
        #expect(failure.code == .transportUnavailable)
        #expect(failure.message.contains("different or unverified build"))
      }
      #expect(await transport.disconnectCallCount == 1)
      #expect(await transport.startCallCount == 0)
    }
    let transport = CountingTransport(executableID: expected)
    let adapter = HexGatewayClientAdapter(
      client: HexGatewayClient(transport: transport),
      authorizationTransport: NoopAuthorizationTransport(), expectedExecutableID: expected)
    #expect(try await adapter.connect().response.executableID == expected)
    #expect(await transport.disconnectCallCount == 0)
    try await adapter.disconnect()
  }

  @Test
  func toolHealthNeverEstablishesAConnectionImplicitly() async throws {
    let transport = CountingTransport()
    let adapter = HexGatewayClientAdapter(
      client: HexGatewayClient(transport: transport),
      authorizationTransport: NoopAuthorizationTransport())
    let client = HexLiveAgentClient(
      configuration: HexDeveloperConfiguration(environment: [:]),
      route: .residentXPC(machServiceName: "com.example.hex.test"),
      initialGatewayAdapter: adapter)

    do {
      _ = try await client.toolServerHealth()
      Issue.record("A disconnected health read must fail without connecting.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .notConnected)
    }
    do {
      _ = try await client.refreshToolServer(GatewayToolServerRequest(serverID: "playwright"))
      Issue.record("A disconnected tool check must fail without connecting.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .notConnected)
    }
    #expect(await transport.handshakeCallCount == 0)
    #expect(await transport.startCallCount == 0)
  }

  @Test
  func statusThenWorkspaceConnectUsesOneHandshake() async throws {
    let transport = CountingTransport()
    let gatewayClient = HexGatewayClient(transport: transport)
    let adapter = HexGatewayClientAdapter(
      client: gatewayClient,
      authorizationTransport: NoopAuthorizationTransport()
    )
    let client = HexLiveAgentClient(
      configuration: HexDeveloperConfiguration(environment: [:]),
      route: .residentXPC(machServiceName: "com.example.hex.test"),
      initialGatewayAdapter: adapter
    )

    #expect(try await client.status() == .idle)
    _ = try await client.connect()

    #expect(await transport.handshakeCallCount == 1)
  }

  @Test
  func concurrentStatusAndWorkspaceConnectShareOneHandshake() async throws {
    let transport = CountingTransport(yieldsBeforeHandshakeResponse: true)
    let gatewayClient = HexGatewayClient(transport: transport)
    let adapter = HexGatewayClientAdapter(
      client: gatewayClient,
      authorizationTransport: NoopAuthorizationTransport()
    )
    let client = HexLiveAgentClient(
      configuration: HexDeveloperConfiguration(environment: [:]),
      route: .residentXPC(machServiceName: "com.example.hex.test"),
      initialGatewayAdapter: adapter
    )

    async let status = client.status()
    async let connection = client.connect()
    let (resolvedStatus, _) = try await (status, connection)

    #expect(resolvedStatus == .idle)
    #expect(await transport.handshakeCallCount == 1)
  }

  @Test
  func screenControlPermissionChecksUseTheResidentTransport() async throws {
    let transport = CountingTransport()
    let gatewayClient = HexGatewayClient(transport: transport)
    let adapter = HexGatewayClientAdapter(
      client: gatewayClient,
      authorizationTransport: NoopAuthorizationTransport()
    )
    let client = HexLiveAgentClient(
      configuration: HexDeveloperConfiguration(environment: [:]),
      route: .residentXPC(machServiceName: "com.example.hex.test"),
      initialGatewayAdapter: adapter
    )

    let status = try await client.screenControlPermissionStatus()

    #expect(status.accessibilityGranted)
    #expect(!status.screenRecordingGranted)
    #expect(await transport.screenControlStatusCallCount == 1)
    #expect(await transport.handshakeCallCount == 1)
  }

  @Test
  func residentConnectionResetForcesTheNextOperationToHandshakeAgain() async throws {
    let transport = CountingTransport()
    let gatewayClient = HexGatewayClient(transport: transport)
    let adapter = HexGatewayClientAdapter(
      client: gatewayClient,
      authorizationTransport: NoopAuthorizationTransport()
    )
    let client = HexLiveAgentClient(
      configuration: HexDeveloperConfiguration(environment: [:]),
      route: .residentXPC(machServiceName: "com.example.hex.test"),
      initialGatewayAdapter: adapter
    )

    #expect(try await client.status() == .idle)
    await client.resetResidentGatewayConnection()
    #expect(try await client.status() == .idle)

    #expect(await transport.disconnectCallCount == 1)
    #expect(await transport.handshakeCallCount == 2)
  }

  @Test(arguments: [
    GatewayFailureCode.disconnected, .transportUnavailable, .staleSession,
    .producerEndedWithoutTerminalEvent,
  ])
  func brokenEventStreamInvalidatesTheCachedHandshake(code: GatewayFailureCode) async throws {
    let transport = CountingTransport(streamFailure: code)
    let adapter = HexGatewayClientAdapter(
      client: HexGatewayClient(transport: transport),
      authorizationTransport: NoopAuthorizationTransport()
    )
    let client = HexLiveAgentClient(
      configuration: HexDeveloperConfiguration(environment: [:]),
      route: .residentXPC(machServiceName: "com.example.hex.test"),
      initialGatewayAdapter: adapter
    )
    _ = try await client.connect()
    let stream = try await client.eventRecords(
      for: AgentRunID(), invocationID: GatewayRunInvocationID(rawValue: UUID()))
    do {
      for try await _ in stream {}
      Issue.record("Expected the event stream to fail.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == code)
    }

    _ = try await client.connect()
    #expect(await transport.handshakeCallCount == 2)
    #expect(await transport.startCallCount == 0)
  }

  @Test
  func terminalRunFailureDoesNotForceAnotherHandshake() async throws {
    let transport = CountingTransport(terminalRunFailure: true)
    let adapter = HexGatewayClientAdapter(
      client: HexGatewayClient(transport: transport),
      authorizationTransport: NoopAuthorizationTransport()
    )
    let client = HexLiveAgentClient(
      configuration: HexDeveloperConfiguration(environment: [:]),
      route: .residentXPC(machServiceName: "com.example.hex.test"),
      initialGatewayAdapter: adapter
    )
    _ = try await client.connect()
    let stream = try await client.eventRecords(
      for: AgentRunID(), invocationID: GatewayRunInvocationID(rawValue: UUID()))
    var count = 0
    for try await _ in stream { count += 1 }
    #expect(count == 1)

    _ = try await client.connect()
    #expect(await transport.handshakeCallCount == 1)
  }

  @Test
  func concurrentStatusAndConnectShareOneRecoveryHandshake() async throws {
    let transport = CountingTransport(
      yieldsBeforeHandshakeResponse: true, streamFailure: .disconnected)
    let adapter = HexGatewayClientAdapter(
      client: HexGatewayClient(transport: transport),
      authorizationTransport: NoopAuthorizationTransport()
    )
    let client = HexLiveAgentClient(
      configuration: HexDeveloperConfiguration(environment: [:]),
      route: .residentXPC(machServiceName: "com.example.hex.test"),
      initialGatewayAdapter: adapter
    )
    _ = try await client.connect()
    let stream = try await client.eventRecords(
      for: AgentRunID(), invocationID: GatewayRunInvocationID(rawValue: UUID()))
    do {
      for try await _ in stream {}
      Issue.record("Expected the event stream to fail.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .disconnected)
    }
    async let status = client.status()
    async let connection = client.connect()
    let (resolvedStatus, _) = try await (status, connection)
    #expect(resolvedStatus == .idle)
    #expect(await transport.handshakeCallCount == 2)
  }

  private struct NoopAuthorizationTransport: HexAuthorizationDecisionSubmitting {
    func submit(
      _ request: AuthorizationRequest,
      choice: AuthorizationDecisionChoice
    ) async throws {}
  }

  private actor CountingTransport: HexGatewayTransport, HexGatewayResidentControlTransport,
    HexGatewayScreenControlPermissionTransport
  {
    private(set) var handshakeCallCount = 0
    private(set) var disconnectCallCount = 0
    private(set) var screenControlStatusCallCount = 0
    private(set) var startCallCount = 0
    private(set) var historyRequests: [GatewayHeartbeatRunListRequest] = []
    private var connectedLease: GatewayTransportConnectionLease?
    private let yieldsBeforeHandshakeResponse: Bool
    private let streamFailure: GatewayFailureCode?
    private let terminalRunFailure: Bool
    private let executableID: UUID?
    private let historyFailure: GatewayFailureCode?

    init(
      yieldsBeforeHandshakeResponse: Bool = false,
      streamFailure: GatewayFailureCode? = nil,
      terminalRunFailure: Bool = false,
      executableID: UUID? = nil,
      historyFailure: GatewayFailureCode? = nil
    ) {
      self.yieldsBeforeHandshakeResponse = yieldsBeforeHandshakeResponse
      self.streamFailure = streamFailure
      self.terminalRunFailure = terminalRunFailure
      self.executableID = executableID
      self.historyFailure = historyFailure
    }

    func handshake(
      _ request: GatewayHandshakeRequest,
      lease: GatewayTransportConnectionLease
    ) async throws -> GatewayHandshakeResponse {
      handshakeCallCount += 1
      if yieldsBeforeHandshakeResponse {
        for _ in 0..<100 where handshakeCallCount < 2 {
          await Task.yield()
        }
      }
      connectedLease = lease
      return GatewayHandshakeResponse(
        sessionID: GatewaySessionID(),
        gatewayInstanceID: GatewayInstanceID(),
        selectedVersion: .current,
        activeRun: nil, executableID: executableID
      )
    }

    func startRun(
      _ request: GatewayStartRunRequest,
      lease: GatewayTransportConnectionLease
    ) async throws -> GatewayStartRunResponse {
      try requireConnection(lease)
      startCallCount += 1
      return GatewayStartRunResponse(
        runID: request.runID,
        disposition: .started(invocationID: GatewayRunInvocationID(rawValue: UUID()))
      )
    }

    func cancelRun(
      _ request: GatewayCancelRunRequest,
      lease: GatewayTransportConnectionLease
    ) async throws -> GatewayCancelRunResponse {
      try requireConnection(lease)
      return GatewayCancelRunResponse(
        runID: request.runID,
        invocationID: request.invocationID,
        disposition: .requested
      )
    }

    func eventRecords(
      after cursor: GatewayEventCursor,
      lease: GatewayTransportConnectionLease
    ) async throws -> AsyncThrowingStream<GatewayEventEnvelope, any Error> {
      try requireConnection(lease)
      return AsyncThrowingStream { continuation in
        if terminalRunFailure {
          continuation.yield(
            GatewayEventEnvelope(
              invocationID: cursor.invocationID,
              record: AgentEventRecord(
                id: AgentEventID(), runID: cursor.runID, sequence: cursor.sequence + 1,
                timestamp: Date(),
                event: .runFailed(
                  AgentFailure(code: .provider, message: "Synthetic failure."))
              )
            ))
        }
        if let streamFailure, streamFailure != .producerEndedWithoutTerminalEvent {
          continuation.finish(
            throwing: GatewayFailure(code: streamFailure, message: "Synthetic stream loss."))
          return
        }
        continuation.finish()
      }
    }

    func disconnect(lease: GatewayTransportConnectionLease) async {
      disconnectCallCount += 1
      if connectedLease == lease {
        connectedLease = nil
      }
    }

    func status(
      lease: GatewayTransportConnectionLease
    ) async throws -> GatewayResidentStatus {
      try requireConnection(lease)
      return .idle
    }

    func pauseHeartbeats(
      lease: GatewayTransportConnectionLease
    ) async throws -> GatewayResidentStatus {
      try requireConnection(lease)
      return .paused
    }

    func listHeartbeatRuns(
      _ request: GatewayHeartbeatRunListRequest,
      lease: GatewayTransportConnectionLease
    ) async throws -> GatewayHeartbeatRunPage {
      try requireConnection(lease)
      historyRequests.append(request)
      if let historyFailure {
        throw GatewayFailure(code: historyFailure, message: "Synthetic history connection loss.")
      }
      return GatewayHeartbeatRunPage(
        storeID: UUID(),
        runs: [
          GatewayHeartbeatRun(
            scheduleID: request.scheduleID ?? UUID(), dueAt: Date(),
            scheduleName: "Saved scheduled read")
        ])
    }

    func resumeHeartbeats(
      lease: GatewayTransportConnectionLease
    ) async throws -> GatewayResidentStatus {
      try requireConnection(lease)
      return .idle
    }

    func screenControlPermissionStatus(
      lease: GatewayTransportConnectionLease
    ) async throws -> GatewayScreenControlPermissionStatus {
      try requireConnection(lease)
      screenControlStatusCallCount += 1
      return GatewayScreenControlPermissionStatus(
        accessibilityGranted: true,
        screenRecordingGranted: false
      )
    }

    func requestScreenControlPermission(
      lease: GatewayTransportConnectionLease
    ) async throws -> GatewayScreenControlPermissionStatus {
      try await screenControlPermissionStatus(lease: lease)
    }

    private func requireConnection(_ lease: GatewayTransportConnectionLease) throws {
      guard connectedLease == lease else {
        throw GatewayFailure(
          code: .notConnected,
          message: "The test transport is not connected."
        )
      }
    }
  }
}
