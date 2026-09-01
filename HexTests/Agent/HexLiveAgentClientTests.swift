import Foundation
import HexCore
import HexIPC
import Testing

@testable import Hex

@Suite("Live agent client connection reuse")
struct HexLiveAgentClientTests {
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

  private struct NoopAuthorizationTransport: HexAuthorizationDecisionSubmitting {
    func submit(
      _ request: AuthorizationRequest,
      choice: AuthorizationDecisionChoice
    ) async throws {}
  }

  private actor CountingTransport: HexGatewayTransport, HexGatewayResidentControlTransport {
    private(set) var handshakeCallCount = 0
    private var connectedLease: GatewayTransportConnectionLease?

    func handshake(
      _ request: GatewayHandshakeRequest,
      lease: GatewayTransportConnectionLease
    ) async throws -> GatewayHandshakeResponse {
      handshakeCallCount += 1
      connectedLease = lease
      return GatewayHandshakeResponse(
        sessionID: GatewaySessionID(),
        gatewayInstanceID: GatewayInstanceID(),
        selectedVersion: .current,
        activeRun: nil
      )
    }

    func startRun(
      _ request: GatewayStartRunRequest,
      lease: GatewayTransportConnectionLease
    ) async throws -> GatewayStartRunResponse {
      try requireConnection(lease)
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
        continuation.finish()
      }
    }

    func disconnect(lease: GatewayTransportConnectionLease) async {
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

    func resumeHeartbeats(
      lease: GatewayTransportConnectionLease
    ) async throws -> GatewayResidentStatus {
      try requireConnection(lease)
      return .idle
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
