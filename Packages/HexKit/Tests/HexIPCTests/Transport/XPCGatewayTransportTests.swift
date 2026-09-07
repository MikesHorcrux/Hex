import Foundation
import HexCore
import HexIPC
import Testing

@Suite("XPC gateway transport")
struct XPCGatewayTransportTests {
  @Test
  func readOnlyRecoveryOperationsCrossTheInjectedConnectionWithoutStartingARun() async throws {
    let runID = GatewayTestValues.runID(175)
    let handshake = GatewayHandshakeResponse(
      sessionID: GatewaySessionID(), gatewayInstanceID: GatewayInstanceID(),
      selectedVersion: .current, activeRun: nil)
    let connection = ScriptedConnection(handshake: handshake, start: nil)
    let transport = XPCGatewayTransport(
      connectionFactory: FixedConnectionFactory(connection: connection))
    let lease = GatewayTransportConnectionLease()
    _ = try await transport.handshake(GatewayTestValues.handshakeRequest(), lease: lease)
    let recovered = try await transport.recoverRun(
      GatewayRunRecoveryRequest(runID: runID), lease: lease)
    #expect(recovered.gatewayInstanceID == handshake.gatewayInstanceID)
    #expect(recovered.disposition == .unknown)
    let record = GatewayTestValues.record(runID: runID, sequence: 1, event: .runStarted)
    let page = try await transport.readRunHistory(
      GatewayRunHistoryRequest(
        runID: runID, firstEventID: record.id, afterSequence: 0, throughSequence: 1), lease: lease)
    #expect(page.records == [record])
    #expect(await connection.operations == [.handshake, .recoverRun, .readRunHistory])
  }

  @Test
  func handshakeRunAndOrderedEventsCrossTheInjectedConnection() async throws {
    let runID = GatewayTestValues.runID(241)
    let invocationID = GatewayTestValues.invocationID(242)
    let handshake = GatewayHandshakeResponse(
      sessionID: GatewaySessionID(rawValue: GatewayTestValues.uuid(243)),
      gatewayInstanceID: GatewayInstanceID(rawValue: GatewayTestValues.uuid(244)),
      selectedVersion: .current,
      activeRun: nil
    )
    let start = GatewayStartRunResponse(
      runID: runID,
      disposition: .started(invocationID: invocationID)
    )
    let connection = ScriptedConnection(
      handshake: handshake,
      start: start
    )
    let transport = XPCGatewayTransport(
      connectionFactory: FixedConnectionFactory(connection: connection)
    )
    let lease = GatewayTransportConnectionLease(rawValue: GatewayTestValues.uuid(245))

    #expect(
      try await transport.handshake(GatewayTestValues.handshakeRequest(), lease: lease) == handshake
    )
    #expect(
      try await transport.startRun(GatewayTestValues.request(runID: runID), lease: lease) == start)

    let stream = try await transport.eventRecords(
      after: GatewayEventCursor(runID: runID, invocationID: invocationID),
      lease: lease
    )
    let first = GatewayTestValues.record(runID: runID, sequence: 1, event: .runStarted)
    let second = GatewayTestValues.record(runID: runID, sequence: 2, event: .runCompleted)
    await connection.emit(first, invocationID: invocationID)
    await connection.emit(second, invocationID: invocationID)
    await connection.finishEvents()

    #expect(try await GatewayTestValues.collect(stream) == [first, second])
    #expect(await connection.operations == [.handshake, .startRun, .subscribeEvents])
  }

  @Test
  func disconnectSendsLeaseBoundOperationAndInvalidatesThePhysicalConnection() async throws {
    let handshake = GatewayHandshakeResponse(
      sessionID: GatewaySessionID(rawValue: GatewayTestValues.uuid(251)),
      gatewayInstanceID: GatewayInstanceID(rawValue: GatewayTestValues.uuid(252)),
      selectedVersion: .current,
      activeRun: nil
    )
    let connection = ScriptedConnection(
      handshake: handshake,
      start: GatewayStartRunResponse(
        runID: GatewayTestValues.runID(253),
        disposition: .started(invocationID: GatewayTestValues.invocationID(254))
      )
    )
    let transport = XPCGatewayTransport(
      connectionFactory: FixedConnectionFactory(connection: connection)
    )
    let lease = GatewayTransportConnectionLease(rawValue: GatewayTestValues.uuid(255))
    _ = try await transport.handshake(GatewayTestValues.handshakeRequest(), lease: lease)

    await transport.disconnect(lease: lease)
    #expect(await connection.operations == [.handshake, .disconnect])
    #expect(await connection.wasInvalidated)

    do {
      _ = try await transport.startRun(
        GatewayTestValues.request(runID: GatewayTestValues.runID(253)),
        lease: lease
      )
      Issue.record("Expected operations after disconnect to be rejected.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .notConnected)
    }
  }

  @Test
  func remoteFailureIsReturnedAsCanonicalGatewayFailure() async throws {
    let handshake = GatewayHandshakeResponse(
      sessionID: GatewaySessionID(rawValue: GatewayTestValues.uuid(161)),
      gatewayInstanceID: GatewayInstanceID(rawValue: GatewayTestValues.uuid(162)),
      selectedVersion: .current,
      activeRun: nil
    )
    let failure = GatewayFailure(
      code: .capacityExceeded,
      message: "capacity is full",
      isRetryable: true
    )
    let connection = ScriptedConnection(
      handshake: handshake,
      start: nil,
      startFailure: failure
    )
    let transport = XPCGatewayTransport(
      connectionFactory: FixedConnectionFactory(connection: connection)
    )
    let lease = GatewayTransportConnectionLease(rawValue: GatewayTestValues.uuid(163))
    _ = try await transport.handshake(GatewayTestValues.handshakeRequest(), lease: lease)

    do {
      _ = try await transport.startRun(
        GatewayTestValues.request(runID: GatewayTestValues.runID(164)),
        lease: lease
      )
      Issue.record("Expected the scripted gateway failure.")
    } catch let received as GatewayFailure {
      #expect(received == failure)
    }
  }

  @Test
  func authorizationDecisionUsesTheActiveLeaseAndEchoesTheExactRequest() async throws {
    let handshake = GatewayHandshakeResponse(
      sessionID: GatewaySessionID(rawValue: GatewayTestValues.uuid(181)),
      gatewayInstanceID: GatewayInstanceID(rawValue: GatewayTestValues.uuid(182)),
      selectedVersion: .current,
      activeRun: nil
    )
    let connection = ScriptedConnection(
      handshake: handshake,
      start: nil
    )
    let transport = XPCGatewayTransport(
      connectionFactory: FixedConnectionFactory(connection: connection)
    )
    let lease = GatewayTransportConnectionLease(rawValue: GatewayTestValues.uuid(183))
    _ = try await transport.handshake(GatewayTestValues.handshakeRequest(184), lease: lease)
    let request = AuthorizationRequest(
      runID: GatewayTestValues.runID(185),
      toolCallID: ToolCallID(rawValue: "call-185"),
      capability: CapabilityID(rawValue: "process.execute"),
      operation: "run",
      resource: "/usr/bin/true",
      details: ["argv_count": .integer(1)],
      explanation: "Allow this exact process invocation."
    )

    try await transport.submitAuthorizationDecision(
      request,
      choice: .allowForSession,
      lease: lease
    )

    #expect(await connection.operations == [.handshake, .submitAuthorizationDecision])
    #expect(
      await connection.authorizationDecision
        == GatewayAuthorizationDecisionRequest(request: request, choice: .allowForSession)
    )

    let staleLease = GatewayTransportConnectionLease(rawValue: GatewayTestValues.uuid(186))
    do {
      try await transport.submitAuthorizationDecision(
        request,
        choice: .deny,
        lease: staleLease
      )
      Issue.record("Expected an authorization response on a stale lease to be rejected.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .notConnected)
    }
  }

  @Test
  func clientRoutesScreenControlPermissionOperationsThroughTheConnectedCapability() async throws {
    let handshake = GatewayHandshakeResponse(
      sessionID: GatewaySessionID(rawValue: GatewayTestValues.uuid(217)),
      gatewayInstanceID: GatewayInstanceID(rawValue: GatewayTestValues.uuid(218)),
      selectedVersion: .current,
      activeRun: nil
    )
    let connection = ScriptedConnection(handshake: handshake, start: nil)
    let client = HexGatewayClient(
      transport: XPCGatewayTransport(
        connectionFactory: FixedConnectionFactory(connection: connection)
      )
    )
    _ = try await client.connect()
    let expected = GatewayScreenControlPermissionStatus(
      accessibilityGranted: false,
      screenRecordingGranted: true
    )

    #expect(try await client.screenControlPermissionStatus() == expected)
    #expect(try await client.requestScreenControlPermission() == expected)
    #expect(
      await connection.operations
        == [.handshake, .screenControlPermissionStatus, .requestScreenControlPermission]
    )
  }

  @Test
  func residentControlOperationsUseTheActiveLeaseAndGeneration() async throws {
    let handshake = GatewayHandshakeResponse(
      sessionID: GatewaySessionID(rawValue: GatewayTestValues.uuid(187)),
      gatewayInstanceID: GatewayInstanceID(rawValue: GatewayTestValues.uuid(188)),
      selectedVersion: .current,
      activeRun: nil
    )
    let connection = ScriptedConnection(handshake: handshake, start: nil)
    let transport = XPCGatewayTransport(
      connectionFactory: FixedConnectionFactory(connection: connection)
    )
    let lease = GatewayTransportConnectionLease(rawValue: GatewayTestValues.uuid(189))
    _ = try await transport.handshake(GatewayTestValues.handshakeRequest(190), lease: lease)

    #expect(try await transport.status(lease: lease) == .unavailable)
    #expect(try await transport.accessibilityPermissionStatus(lease: lease) == .notTrusted)
    #expect(try await transport.requestAccessibilityPermission(lease: lease) == .notTrusted)
    let screenControlStatus = GatewayScreenControlPermissionStatus(
      accessibilityGranted: false,
      screenRecordingGranted: true
    )
    #expect(
      try await transport.screenControlPermissionStatus(lease: lease) == screenControlStatus
    )
    #expect(
      try await transport.requestScreenControlPermission(lease: lease) == screenControlStatus
    )
    #expect(try await transport.pauseHeartbeats(lease: lease) == .unavailable)
    #expect(try await transport.resumeHeartbeats(lease: lease) == .unavailable)
    #expect(try await transport.listHeartbeats(lease: lease) == GatewayHeartbeatScheduleList())
    let scheduleRequest = GatewayHeartbeatScheduleRequest(
      id: GatewayTestValues.uuid(192),
      name: "Test heartbeat",
      instruction: "Check the current context.",
      intervalSeconds: 60,
      nextDueAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let scheduleMutation = GatewayHeartbeatScheduleMutation(scheduleID: scheduleRequest.id)
    #expect(
      try await transport.addHeartbeat(scheduleRequest, lease: lease)
        == GatewayHeartbeatScheduleList()
    )
    #expect(
      try await transport.removeHeartbeat(scheduleMutation, lease: lease)
        == GatewayHeartbeatScheduleList()
    )
    #expect(
      try await transport.pauseHeartbeat(scheduleMutation, lease: lease)
        == GatewayHeartbeatScheduleList()
    )
    #expect(
      try await transport.resumeHeartbeat(scheduleMutation, lease: lease)
        == GatewayHeartbeatScheduleList()
    )
    #expect(
      await connection.operations
        == [
          .handshake,
          .status,
          .accessibilityPermissionStatus,
          .requestAccessibilityPermission,
          .screenControlPermissionStatus,
          .requestScreenControlPermission,
          .pauseHeartbeats,
          .resumeHeartbeats,
          .listHeartbeats,
          .addHeartbeat,
          .removeHeartbeat,
          .pauseHeartbeat,
          .resumeHeartbeat,
        ]
    )

    let staleLease = GatewayTransportConnectionLease(rawValue: GatewayTestValues.uuid(191))
    do {
      _ = try await transport.status(lease: staleLease)
      Issue.record("Expected a resident status request on a stale lease to be rejected.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .notConnected)
    }
  }

  @Test
  func exportedServiceAdaptsHandshakeRunAndEventSubscription() async throws {
    let driver = ImmediateGatewayRunDriver()
    let gateway = HexGatewayService(driver: driver)
    let exportedService = HexGatewayXPCService(service: gateway)
    let codec = GatewayWireCodec(configuration: .standard)
    let lease = GatewayTransportConnectionLease(rawValue: GatewayTestValues.uuid(171))
    let handshakeRequest = GatewayTestValues.handshakeRequest(172)
    let handshakeEnvelope = try codec.encode(
      GatewayXPCRequestEnvelope(
        operation: .handshake,
        lease: lease,
        body: try codec.encode(handshakeRequest)
      )
    )
    let handshakeResponseData = try await Self.sendRequest(
      handshakeEnvelope,
      to: exportedService
    )
    let handshakeResponse = try responseValue(
      handshakeResponseData,
      operation: .handshake,
      as: GatewayHandshakeResponse.self,
      codec: codec
    )

    let runID = GatewayTestValues.runID(173)
    let startRequest = GatewayTestValues.request(runID: runID)
    let startEnvelope = try codec.encode(
      GatewayXPCRequestEnvelope(
        operation: .startRun,
        lease: lease,
        sessionID: handshakeResponse.sessionID,
        body: try codec.encode(startRequest)
      )
    )
    let sinkStore = EventSinkStore()
    let sink = RecordingEventSink(store: sinkStore)
    let subscriptionID = GatewayXPCSubscriptionID()
    // The gateway needs a run generation before it can accept the cursor. Start first, then use the
    // invocation identity returned by admission to subscribe to the ordered stream.
    let startResponseData = try await Self.sendRequest(startEnvelope, to: exportedService)
    let startResponse = try responseValue(
      startResponseData,
      operation: .startRun,
      as: GatewayStartRunResponse.self,
      codec: codec
    )
    let invocationID = try #require(startResponse.invocationID)
    let validSubscribeEnvelope = try codec.encode(
      GatewayXPCRequestEnvelope(
        operation: .subscribeEvents,
        lease: lease,
        sessionID: handshakeResponse.sessionID,
        subscriptionID: subscriptionID,
        body: try codec.encode(
          GatewayEventCursor(runID: runID, invocationID: invocationID)
        )
      )
    )
    _ = try await sendSubscribe(
      validSubscribeEnvelope,
      sink: sink,
      to: exportedService
    )
    await sinkStore.waitUntilFinished()
    let eventData = await sinkStore.events
    #expect(eventData.count == 2)
    let events = try eventData.map {
      try codec.decode(GatewayEventEnvelope.self, from: $0)
    }
    #expect(events.map(\.record.sequence) == [1, 2])
    #expect(await sinkStore.completionFailure == nil)
  }

  @Test
  func exportedServiceRejectsMalformedAndStaleAuthorizationDecisions() async throws {
    let store = DecisionStore()
    let gateway = HexGatewayService(driver: ImmediateGatewayRunDriver())
    let exportedService = HexGatewayXPCService(
      service: gateway,
      authorizationDecisionHandler: { request, choice, _ in
        await store.record(request: request, choice: choice)
      }
    )
    let codec = GatewayWireCodec(configuration: .standard)
    let lease = GatewayTransportConnectionLease(rawValue: GatewayTestValues.uuid(191))
    let handshakeData = try codec.encode(
      GatewayXPCRequestEnvelope(
        operation: .handshake,
        lease: lease,
        body: try codec.encode(GatewayTestValues.handshakeRequest(192))
      )
    )
    let handshakeRawResponse = try await Self.sendRequest(handshakeData, to: exportedService)
    let handshakeResponse = try responseValue(
      handshakeRawResponse,
      operation: .handshake,
      as: GatewayHandshakeResponse.self,
      codec: codec
    )
    let request = AuthorizationRequest(
      runID: GatewayTestValues.runID(193),
      capability: CapabilityID(rawValue: "process.execute"),
      operation: "run",
      details: ["argv_count": .integer(1)],
      explanation: "Allow this exact process invocation."
    )
    let validData = try codec.encode(
      GatewayXPCRequestEnvelope(
        operation: .submitAuthorizationDecision,
        lease: lease,
        sessionID: handshakeResponse.sessionID,
        body: try codec.encode(
          GatewayAuthorizationDecisionRequest(request: request, choice: .allowOnce)
        )
      )
    )
    let validResponseData = try await Self.sendRequest(validData, to: exportedService)
    let validResponse = try codec.decode(
      GatewayXPCResponseEnvelope.self,
      from: validResponseData
    ).validated()
    #expect(validResponse.failure == nil)
    #expect(validResponse.body == nil)
    #expect(await store.request == request)
    #expect(await store.choice == .allowOnce)

    let staleSessionData = try codec.encode(
      GatewayXPCRequestEnvelope(
        operation: .submitAuthorizationDecision,
        lease: lease,
        sessionID: GatewaySessionID(rawValue: GatewayTestValues.uuid(194)),
        body: try codec.encode(
          GatewayAuthorizationDecisionRequest(request: request, choice: .deny)
        )
      )
    )
    let staleResponseData = try await Self.sendRequest(staleSessionData, to: exportedService)
    let staleResponse = try codec.decode(
      GatewayXPCResponseEnvelope.self,
      from: staleResponseData
    ).validated()
    #expect(staleResponse.failure?.code == .staleSession)

    let malformedData = try codec.encode(
      GatewayXPCRequestEnvelope(
        operation: .submitAuthorizationDecision,
        lease: lease,
        sessionID: handshakeResponse.sessionID,
        body: Data([0xFF])
      )
    )
    let malformedResponseData = try await Self.sendRequest(malformedData, to: exportedService)
    let malformedResponse = try codec.decode(
      GatewayXPCResponseEnvelope.self,
      from: malformedResponseData
    ).validated()
    #expect(malformedResponse.failure?.code == .malformedPayload)
  }

  @Test
  func replacementHandshakeInvalidatesThePreviousAuthorizationCommitGate() async throws {
    let coordinator = AuthorizationCommitCoordinator()
    let gateway = HexGatewayService(driver: ImmediateGatewayRunDriver())
    let requestHarness = XPCServiceRequestHarness(
      service: HexGatewayXPCService(
        service: gateway,
        authorizationDecisionHandler: { _, _, gate in
          await coordinator.enter()
          await coordinator.waitForRelease()
          do {
            try gate.withValidCommit {}
            await coordinator.recordCommit()
          } catch HexGatewayAuthorizationCommitGate.GateError.closed {
            await coordinator.recordRejection()
          }
        }
      )
    )
    let codec = GatewayWireCodec(configuration: .standard)
    let firstLease = GatewayTransportConnectionLease(rawValue: GatewayTestValues.uuid(201))
    let firstHandshake = try codec.encode(
      GatewayXPCRequestEnvelope(
        operation: .handshake,
        lease: firstLease,
        body: try codec.encode(GatewayTestValues.handshakeRequest(202))
      )
    )
    let firstHandshakeData = await requestHarness.send(firstHandshake)
    let firstHandshakeResponse = try responseValue(
      firstHandshakeData,
      operation: .handshake,
      as: GatewayHandshakeResponse.self,
      codec: codec
    )
    let request = AuthorizationRequest(
      runID: GatewayTestValues.runID(203),
      capability: CapabilityID(rawValue: "process.execute"),
      operation: "run",
      details: ["argv_count": .integer(1)],
      explanation: "Allow this exact process invocation."
    )
    let decision = try codec.encode(
      GatewayXPCRequestEnvelope(
        operation: .submitAuthorizationDecision,
        lease: firstLease,
        sessionID: firstHandshakeResponse.sessionID,
        body: try codec.encode(
          GatewayAuthorizationDecisionRequest(request: request, choice: .allowOnce)
        )
      )
    )
    let decisionTask = Task {
      await requestHarness.send(decision)
    }
    await coordinator.waitUntilEntered()

    let replacementLease = GatewayTransportConnectionLease(rawValue: GatewayTestValues.uuid(204))
    let replacementHandshake = try codec.encode(
      GatewayXPCRequestEnvelope(
        operation: .handshake,
        lease: replacementLease,
        body: try codec.encode(GatewayTestValues.handshakeRequest(205))
      )
    )
    let replacementHandshakeData = await requestHarness.send(replacementHandshake)
    _ = try responseValue(
      replacementHandshakeData,
      operation: .handshake,
      as: GatewayHandshakeResponse.self,
      codec: codec
    )
    await coordinator.release()
    _ = await decisionTask.value

    #expect(await coordinator.didCommit == false)
    #expect(await coordinator.wasRejected)
  }

  private actor ScriptedConnection: HexGatewayXPCConnection {
    private let codec = GatewayWireCodec(configuration: .standard)
    private let handshakeResponse: GatewayHandshakeResponse
    private let startResponse: GatewayStartRunResponse?
    private let startFailure: GatewayFailure?
    private(set) var authorizationDecision: GatewayAuthorizationDecisionRequest?
    private var eventContinuations:
      [GatewayXPCSubscriptionID: AsyncThrowingStream<Data, any Error>.Continuation] = [:]
    private(set) var operations: [GatewayXPCOperation] = []
    private(set) var wasInvalidated = false

    init(
      handshake: GatewayHandshakeResponse,
      start: GatewayStartRunResponse?,
      startFailure: GatewayFailure? = nil
    ) {
      handshakeResponse = handshake
      startResponse = start
      self.startFailure = startFailure
      authorizationDecision = nil
    }

    func request(_ rawEnvelope: Data) async throws -> Data {
      let envelope = try codec.decode(GatewayXPCRequestEnvelope.self, from: rawEnvelope)
      operations.append(envelope.operation)
      switch envelope.operation {
      case .handshake:
        return try response(operation: .handshake, value: handshakeResponse)
      case .availableModels:
        return try response(operation: .availableModels, value: [ModelDescriptor]())
      case .toolServerHealth, .refreshToolServer, .approvalInbox, .revokeSessionGrant,
        .folderAccessStatus:
        return try codec.encode(
          GatewayXPCResponseEnvelope(
            operation: envelope.operation,
            failure: GatewayFailure(code: .transportUnavailable, message: "Not scripted.")))
      case .readArtifact:
        return try codec.encode(
          GatewayXPCResponseEnvelope(
            operation: .readArtifact,
            failure: GatewayFailure(code: .artifactUnavailable, message: "not scripted")))
      case .recoverRun:
        let request = try codec.decode(GatewayRunRecoveryRequest.self, from: envelope.body)
        return try response(
          operation: .recoverRun,
          value: GatewayRunRecoveryResponse(
            gatewayInstanceID: handshakeResponse.gatewayInstanceID, runID: request.runID,
            disposition: .unknown))
      case .readRunHistory:
        let request = try codec.decode(GatewayRunHistoryRequest.self, from: envelope.body)
        let record = GatewayTestValues.record(runID: request.runID, sequence: 1, event: .runStarted)
        return try response(
          operation: .readRunHistory,
          value: GatewayRunHistoryPage(
            gatewayInstanceID: handshakeResponse.gatewayInstanceID, runID: request.runID,
            firstEventID: request.firstEventID, afterSequence: request.afterSequence,
            throughSequence: request.throughSequence, records: [record], nextAfterSequence: nil))
      case .startRun:
        if let startFailure {
          return try codec.encode(
            GatewayXPCResponseEnvelope(operation: .startRun, failure: startFailure)
          )
        }
        guard let startResponse else {
          throw GatewayFailure(code: .transportUnavailable, message: "No scripted start response.")
        }
        return try response(operation: .startRun, value: startResponse)
      case .cancelRun:
        return try codec.encode(
          GatewayXPCResponseEnvelope(
            operation: .cancelRun,
            failure: GatewayFailure(code: .runNotFound, message: "not scripted")
          )
        )
      case .submitAuthorizationDecision:
        authorizationDecision = try codec.decode(
          GatewayAuthorizationDecisionRequest.self,
          from: envelope.body
        )
        return try codec.encode(
          GatewayXPCResponseEnvelope(
            operation: .submitAuthorizationDecision,
            body: nil
          )
        )
      case .status, .pauseHeartbeats, .resumeHeartbeats:
        return try response(
          operation: envelope.operation,
          value: GatewayResidentStatus.unavailable
        )
      case .accessibilityPermissionStatus, .requestAccessibilityPermission:
        return try response(
          operation: envelope.operation,
          value: GatewayAccessibilityPermissionStatus.notTrusted
        )
      case .screenControlPermissionStatus, .requestScreenControlPermission:
        return try response(
          operation: envelope.operation,
          value: GatewayScreenControlPermissionStatus(
            accessibilityGranted: false,
            screenRecordingGranted: true
          )
        )
      case .listHeartbeats, .addHeartbeat, .removeHeartbeat, .pauseHeartbeat, .resumeHeartbeat:
        return try response(
          operation: envelope.operation,
          value: GatewayHeartbeatScheduleList()
        )
      case .listHeartbeatRuns:
        return try response(
          operation: .listHeartbeatRuns,
          value: GatewayHeartbeatRunPage(storeID: GatewayTestValues.uuid(233), runs: []))
      case .disconnect, .cancelSubscription:
        return try codec.encode(
          GatewayXPCResponseEnvelope(operation: envelope.operation, body: nil)
        )
      case .subscribeEvents:
        throw GatewayFailure(code: .malformedPayload, message: "subscription uses subscribe")
      }
    }

    func subscribe(
      _ rawEnvelope: Data,
      bufferCapacity: Int
    ) async throws -> GatewayXPCEventSubscription {
      let envelope = try codec.decode(GatewayXPCRequestEnvelope.self, from: rawEnvelope)
      guard envelope.operation == .subscribeEvents,
        let subscriptionID = envelope.subscriptionID
      else {
        throw GatewayFailure(code: .malformedPayload, message: "invalid subscription")
      }
      operations.append(.subscribeEvents)
      let pair = AsyncThrowingStream<Data, any Error>.makeStream(
        bufferingPolicy: .bufferingOldest(bufferCapacity)
      )
      eventContinuations[subscriptionID] = pair.continuation
      return GatewayXPCEventSubscription(
        id: subscriptionID,
        stream: pair.stream,
        cancellation: { [self] in
          await self.cancelSubscription(rawEnvelope)
        }
      )
    }

    func cancelSubscription(_ rawEnvelope: Data) async {
      guard let envelope = try? codec.decode(GatewayXPCRequestEnvelope.self, from: rawEnvelope),
        let subscriptionID = envelope.subscriptionID
      else {
        return
      }
      eventContinuations.removeValue(forKey: subscriptionID)?.finish()
      operations.append(.cancelSubscription)
    }

    func invalidate() async {
      wasInvalidated = true
      for continuation in eventContinuations.values {
        continuation.finish(throwing: GatewayFailure(code: .disconnected, message: "invalidated"))
      }
      eventContinuations.removeAll()
    }

    func emit(_ record: AgentEventRecord, invocationID: GatewayRunInvocationID) {
      let envelope = GatewayEventEnvelope(invocationID: invocationID, record: record)
      guard let data = try? codec.encode(envelope) else {
        return
      }
      for continuation in eventContinuations.values {
        _ = continuation.yield(data)
      }
    }

    func finishEvents() {
      for continuation in eventContinuations.values {
        continuation.finish()
      }
      eventContinuations.removeAll()
    }

    private func response<Value: Codable & Sendable>(
      operation: GatewayXPCOperation,
      value: Value
    ) throws -> Data {
      let body = try codec.encode(value)
      return try codec.encode(
        GatewayXPCResponseEnvelope(operation: operation, body: body)
      )
    }
  }

  private actor ResponseStore {
    private var value: Data?

    func set(_ value: Data) {
      self.value = value
    }

    func wait() async -> Data {
      while value == nil {
        await Task.yield()
      }
      return value ?? Data()
    }
  }

  private actor XPCServiceRequestHarness {
    private let service: HexGatewayXPCService

    init(service: HexGatewayXPCService) {
      self.service = service
    }

    func send(_ envelope: Data) async -> Data {
      let store = ResponseStore()
      service.request(envelope) { response in
        Task {
          await store.set(response)
        }
      }
      return await store.wait()
    }
  }

  private actor EventSinkStore {
    private(set) var events: [Data] = []
    private(set) var completionFailure: GatewayFailure?
    private var isFinished = false

    func append(_ event: Data) {
      events.append(event)
    }

    func finish(_ response: Data) {
      let codec = GatewayWireCodec(configuration: .standard)
      if let envelope = try? codec.decode(GatewayXPCResponseEnvelope.self, from: response),
        let failure = envelope.failure
      {
        completionFailure = failure
      }
      isFinished = true
    }

    func waitUntilFinished() async {
      while !isFinished {
        await Task.yield()
      }
    }
  }

  private actor DecisionStore {
    private(set) var request: AuthorizationRequest?
    private(set) var choice: GatewayAuthorizationDecisionChoice?

    func record(
      request: AuthorizationRequest,
      choice: GatewayAuthorizationDecisionChoice
    ) {
      self.request = request
      self.choice = choice
    }
  }

  private actor AuthorizationCommitCoordinator {
    private(set) var didCommit = false
    private(set) var wasRejected = false
    private var hasEntered = false
    private var hasReleased = false
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func enter() {
      hasEntered = true
      enteredContinuation?.resume()
      enteredContinuation = nil
    }

    func waitUntilEntered() async {
      guard !hasEntered else {
        return
      }
      await withCheckedContinuation { continuation in
        enteredContinuation = continuation
      }
    }

    func waitForRelease() async {
      guard !hasReleased else {
        return
      }
      await withCheckedContinuation { continuation in
        releaseContinuation = continuation
      }
    }

    func release() {
      hasReleased = true
      releaseContinuation?.resume()
      releaseContinuation = nil
    }

    func recordCommit() {
      didCommit = true
    }

    func recordRejection() {
      wasRejected = true
    }
  }

  private final class RecordingEventSink: NSObject, HexGatewayXPCEventSinkProtocol {
    private let store: EventSinkStore

    init(store: EventSinkStore) {
      self.store = store
      super.init()
    }

    func receiveEvent(_ envelope: Data, withReply reply: @escaping @Sendable (Bool) -> Void) {
      Task {
        await store.append(envelope)
        reply(true)
      }
    }

    func finish(_ response: Data) {
      Task {
        await store.finish(response)
      }
    }
  }

  private static func sendRequest(
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

  private func sendSubscribe(
    _ envelope: Data,
    sink: RecordingEventSink,
    to service: HexGatewayXPCService
  ) async throws -> Data {
    let store = ResponseStore()
    service.subscribe(envelope, sink: sink) { response in
      Task {
        await store.set(response)
      }
    }
    return await store.wait()
  }

  private func responseValue<Value: Codable & Sendable>(
    _ data: Data,
    operation: GatewayXPCOperation,
    as type: Value.Type,
    codec: GatewayWireCodec
  ) throws -> Value {
    let response = try codec.decode(GatewayXPCResponseEnvelope.self, from: data).validated()
    #expect(response.operation == operation)
    if let failure = response.failure {
      throw failure
    }
    return try codec.decode(type, from: try #require(response.body))
  }

  private struct FixedConnectionFactory: HexGatewayXPCConnectionFactory {
    let connection: ScriptedConnection

    func makeConnection() -> any HexGatewayXPCConnection {
      connection
    }
  }
}
