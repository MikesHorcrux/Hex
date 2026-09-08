import Foundation
import HexCore
import HexGatewayKit
import HexIPC
import Testing

@Suite("Gateway heartbeat runner")
struct HexGatewayHeartbeatRunnerTests {
  @Test
  func startsOneAdmittedRunAndAcknowledgesItsTerminalEvent() async throws {
    let transport = ScriptedTransport(mode: .success)
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()
    let workspaceRoot = URL(fileURLWithPath: "/tmp/hex-heartbeat-workspace")
    let runner = try HexGatewayHeartbeatRunner(
      client: client,
      authorizationPolicy: HexHeartbeatAuthorizationPolicy(
        interactivePrompter: HexGatewayAuthorizationBroker()),
      modelID: ModelID(rawValue: "test-model"),
      workspaceRoot: workspaceRoot,
      configuration: Self.runnerConfiguration()
    )

    let request = try Self.executionRequest(instruction: "inspect the workspace")
    let result = try await runner.run(request)

    #expect(result == .succeeded)
    let startedRequest = await transport.startedRequest()
    #expect(startedRequest?.modelID == ModelID(rawValue: "test-model"))
    #expect(startedRequest?.workingDirectory == workspaceRoot)
    #expect(startedRequest?.initialMessages.count == 1)
    #expect(await transport.eventRecordRequestCount() == 1)
    #expect(await transport.cancelRequestCount() == 0)

    let runID = try #require(startedRequest?.runID)
    let invocationID = try #require(await transport.invocationID())
    #expect(
      await client.acknowledgedCursor(for: runID, invocationID: invocationID).sequence == 3
    )
  }

  @Test(arguments: [false, true])
  func busyAdmissionReturnsRetryableFailureWithoutOpeningAnEventStream(maintenance: Bool)
    async throws
  {
    let transport = ScriptedTransport(mode: maintenance ? .maintenance : .busy)
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()
    let runner = try HexGatewayHeartbeatRunner(
      client: client,
      authorizationPolicy: HexHeartbeatAuthorizationPolicy(
        interactivePrompter: HexGatewayAuthorizationBroker()),
      modelID: ModelID(rawValue: "test-model"),
      workspaceRoot: URL(fileURLWithPath: "/tmp/hex-heartbeat-workspace"),
      configuration: Self.runnerConfiguration()
    )

    let result = try await runner.run(Self.executionRequest())

    guard case .failed(let failure) = result else {
      Issue.record("Expected a typed busy failure.")
      return
    }
    #expect(failure.code == .gatewayBusy)
    #expect(failure.retryable)
    #expect(await transport.eventRecordRequestCount() == 0)
    #expect(await transport.cancelRequestCount() == 0)
  }

  @Test
  func authorizationAuditDoesNotCancelOrMisclassifyTheActualTerminalOutcome() async throws {
    let transport = ScriptedTransport(mode: .authorization)
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()
    let runner = try HexGatewayHeartbeatRunner(
      client: client,
      authorizationPolicy: HexHeartbeatAuthorizationPolicy(
        interactivePrompter: HexGatewayAuthorizationBroker()),
      modelID: ModelID(rawValue: "test-model"),
      workspaceRoot: URL(fileURLWithPath: "/tmp/hex-heartbeat-workspace"),
      configuration: Self.runnerConfiguration()
    )

    let result = try await runner.run(Self.executionRequest())

    guard case .failed(let failure) = result else {
      Issue.record("Expected the actual cancelled outcome, not an inferred approval requirement.")
      return
    }
    #expect(failure.code == .cancelled)
    #expect(failure.retryable)
    #expect(await transport.cancelRequestCount() == 0)

    let startedRequest = await transport.startedRequest()
    let runID = try #require(startedRequest?.runID)
    let invocationID = try #require(await transport.invocationID())
    #expect(
      await client.acknowledgedCursor(for: runID, invocationID: invocationID).sequence == 3
    )
  }

  @Test
  func runTimeoutMustBeShorterThanLease() async throws {
    let transport = ScriptedTransport(mode: .success)
    let client = HexGatewayClient(transport: transport)
    let invalidConfiguration = HexHeartbeatSchedulerConfiguration(
      leaseDurationSeconds: 10,
      runTimeoutSeconds: 10
    )

    do {
      _ = try HexGatewayHeartbeatRunner(
        client: client,
        authorizationPolicy: HexHeartbeatAuthorizationPolicy(
          interactivePrompter: HexGatewayAuthorizationBroker()),
        modelID: ModelID(rawValue: "test-model"),
        workspaceRoot: URL(fileURLWithPath: "/tmp/hex-heartbeat-workspace"),
        configuration: invalidConfiguration
      )
      Issue.record("Expected a run timeout equal to the lease to be rejected.")
    } catch let error as HexHeartbeatSchedulerError {
      guard case .invalidConfiguration = error else {
        Issue.record("Expected invalid heartbeat configuration, received: \(error).")
        return
      }
    }
  }

  private static func runnerConfiguration() -> HexHeartbeatSchedulerConfiguration {
    HexHeartbeatSchedulerConfiguration(
      leaseDurationSeconds: 10,
      runTimeoutSeconds: 5
    )
  }

  private static func executionRequest(
    instruction: String = "run heartbeat"
  ) throws -> HexHeartbeatExecutionRequest {
    let dueAt = Date(timeIntervalSinceReferenceDate: 1_000)
    let schedule = try HexHeartbeatSchedule(
      name: "test heartbeat",
      instruction: instruction,
      intervalSeconds: 60,
      nextDueAt: dueAt
    )
    let occurrence = schedule.occurrence()
    return HexHeartbeatExecutionRequest(
      schedule: schedule,
      occurrence: occurrence,
      lease: HexHeartbeatLease(
        occurrence: occurrence,
        claimedAt: dueAt,
        expiresAt: dueAt.addingTimeInterval(10), runID: AgentRunID()
      )
    )
  }

  private actor ScriptedTransport: HexGatewayTransport {
    enum Mode: Sendable {
      case success
      case busy
      case maintenance
      case authorization
    }

    private let mode: Mode
    private var connectedLease: GatewayTransportConnectionLease?
    private var started: GatewayStartRunRequest?
    private var invocation: GatewayRunInvocationID?
    private var eventRecordRequests = 0
    private var cancelRequests = 0
    private var events: [GatewayEventEnvelope] = []

    init(mode: Mode) {
      self.mode = mode
    }

    func handshake(
      _ request: GatewayHandshakeRequest,
      lease: GatewayTransportConnectionLease
    ) async throws -> GatewayHandshakeResponse {
      _ = request
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
      try requireConnection(lease: lease)
      started = request
      switch mode {
      case .maintenance:
        throw GatewayFailure(
          code: .toolMaintenanceInProgress, message: "Tool check in progress.", isRetryable: true)
      case .busy:
        return GatewayStartRunResponse(
          runID: request.runID,
          disposition: .busy(activeRunID: AgentRunID())
        )
      case .success, .authorization:
        let invocationID = GatewayRunInvocationID(rawValue: UUID())
        invocation = invocationID
        events = Self.makeEvents(
          runID: request.runID,
          invocationID: invocationID,
          mode: mode
        )
        return GatewayStartRunResponse(
          runID: request.runID,
          disposition: .started(invocationID: invocationID)
        )
      }
    }

    func cancelRun(
      _ request: GatewayCancelRunRequest,
      lease: GatewayTransportConnectionLease
    ) async throws -> GatewayCancelRunResponse {
      try requireConnection(lease: lease)
      cancelRequests += 1
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
      try requireConnection(lease: lease)
      eventRecordRequests += 1
      let availableEvents = self.events.filter { $0.record.sequence > cursor.sequence }
      return AsyncThrowingStream { continuation in
        for event in availableEvents {
          continuation.yield(event)
        }
        continuation.finish()
      }
    }

    func disconnect(lease: GatewayTransportConnectionLease) async {
      guard connectedLease == lease else {
        return
      }
      connectedLease = nil
    }

    func startedRequest() -> GatewayStartRunRequest? {
      started
    }

    func invocationID() -> GatewayRunInvocationID? {
      invocation
    }

    func eventRecordRequestCount() -> Int {
      eventRecordRequests
    }

    func cancelRequestCount() -> Int {
      cancelRequests
    }

    private func requireConnection(
      lease: GatewayTransportConnectionLease
    ) throws {
      guard connectedLease == lease else {
        throw GatewayFailure(
          code: .notConnected,
          message: "The scripted transport is disconnected."
        )
      }
    }

    private static func makeEvents(
      runID: AgentRunID,
      invocationID: GatewayRunInvocationID,
      mode: Mode
    ) -> [GatewayEventEnvelope] {
      let eventList: [AgentEvent]
      switch mode {
      case .success:
        eventList = [
          .runStarted,
          .messageAppended(
            Message(role: .assistant, content: [.text("done")])
          ),
          .runCompleted,
        ]
      case .authorization:
        eventList = [
          .runStarted,
          .authorizationRequested(
            AuthorizationRequest(
              runID: runID,
              capability: CapabilityID(rawValue: "process.execute"),
              operation: "run",
              explanation: "The heartbeat needs to execute a command."
            )
          ),
          .runCancelled,
        ]
      case .busy, .maintenance:
        eventList = []
      }
      return eventList.enumerated().map { offset, event in
        GatewayEventEnvelope(
          invocationID: invocationID,
          record: AgentEventRecord(
            id: AgentEventID(),
            runID: runID,
            sequence: UInt64(offset + 1),
            timestamp: Date(timeIntervalSinceReferenceDate: TimeInterval(offset + 1)),
            event: event
          )
        )
      }
    }
  }
}
