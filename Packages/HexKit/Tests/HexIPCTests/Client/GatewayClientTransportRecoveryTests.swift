import Foundation
import HexCore
import Testing

@testable import HexIPC

@Suite("Gateway client transport recovery")
struct GatewayClientTransportRecoveryTests {
  @Test(arguments: StreamLoss.allCases)
  func droppedStreamRequiresHandshakeButPreservesAcknowledgementAndRunIdentity(
    loss: StreamLoss
  ) async throws {
    let transport = RecoveryTransport()
    let client = HexGatewayClient(transport: transport)
    let request = GatewayTestValues.request(runID: GatewayTestValues.runID(181))
    _ = try await client.connect()
    let start = try await client.startRun(request)
    let invocationID = try #require(start.invocationID)
    let stream = try await client.eventRecords(for: request.runID, invocationID: invocationID)
    var iterator = stream.makeAsyncIterator()
    let first = GatewayEventEnvelope(
      invocationID: invocationID,
      record: GatewayTestValues.record(runID: request.runID, sequence: 1, event: .runStarted)
    )
    await transport.yield(first)
    #expect(try await iterator.next() == first)
    #expect(try await client.shouldApply(first))
    try await client.acknowledge(first)

    await transport.endStream(loss: loss)
    do {
      _ = try await iterator.next()
      Issue.record("Expected the interrupted stream to fail.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == loss.failureCode)
    }
    await expectDisconnected(client)
    #expect(
      await client.acknowledgedCursor(for: request.runID, invocationID: invocationID).sequence == 1)

    _ = try await client.connect()
    let retried = try await client.startRun(request)
    #expect(retried.disposition == .alreadyRunning(invocationID: invocationID))
    #expect(await transport.startRequests == [request, request])
    #expect(await transport.admissionCount == 1)
    let replay = try await client.eventRecords(for: request.runID, invocationID: invocationID)
    let terminal = GatewayEventEnvelope(
      invocationID: invocationID,
      record: GatewayTestValues.record(runID: request.runID, sequence: 2, event: .runCompleted)
    )
    await transport.yield(terminal)
    await transport.finishStream()
    var replayed: [GatewayEventEnvelope] = []
    for try await envelope in replay {
      #expect(try await client.shouldApply(envelope))
      replayed.append(envelope)
      try await client.acknowledge(envelope)
    }
    #expect(replayed == [terminal])
    #expect(await transport.cursors.map(\.sequence) == [0, 1])
    #expect(
      await client.acknowledgedCursor(for: request.runID, invocationID: invocationID).sequence == 2)
  }

  @Test
  func actualTerminalRunFailureDoesNotInvalidateTheSession() async throws {
    let transport = RecoveryTransport()
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()
    let runID = GatewayTestValues.runID(182)
    let invocationID = GatewayTestValues.invocationID(182)
    let stream = try await client.eventRecords(for: runID, invocationID: invocationID)
    let failure = AgentFailure(code: .provider, message: "Synthetic provider failure.")
    await transport.yield(
      GatewayEventEnvelope(
        invocationID: invocationID,
        record: GatewayTestValues.record(runID: runID, sequence: 1, event: .runFailed(failure))
      ))
    await transport.finishStream()
    #expect(try await GatewayTestValues.collect(stream).count == 1)
    #expect((try? await client.requireConnectedGeneration()) != nil)
  }

  @Test
  func consumerCancellationDoesNotInvalidateTheSession() async throws {
    let transport = RecoveryTransport()
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()
    let stream = try await client.eventRecords(
      for: GatewayTestValues.runID(183), invocationID: GatewayTestValues.invocationID(183))
    let consumer = Task {
      for try await _ in stream {}
    }
    consumer.cancel()
    _ = await consumer.result
    #expect((try? await client.requireConnectedGeneration()) != nil)
  }

  @Test
  func connectionLossAfterTerminalKeepsTheTerminalAcknowledgement() async throws {
    let transport = RecoveryTransport()
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()
    let runID = GatewayTestValues.runID(186)
    let invocationID = GatewayTestValues.invocationID(186)
    let stream = try await client.eventRecords(for: runID, invocationID: invocationID)
    var iterator = stream.makeAsyncIterator()
    let terminal = GatewayEventEnvelope(
      invocationID: invocationID,
      record: GatewayTestValues.record(runID: runID, sequence: 1, event: .runCompleted))
    await transport.yield(terminal)
    #expect(try await iterator.next() == terminal)
    try await client.acknowledge(terminal)
    await transport.endStream(loss: .disconnected)
    do {
      _ = try await iterator.next()
      Issue.record("Expected the physical connection loss to remain visible.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .disconnected)
    }
    #expect(await client.acknowledgedCursor(for: runID, invocationID: invocationID).sequence == 1)
    _ = try await client.connect()
    let replay = try await client.eventRecords(for: runID, invocationID: invocationID)
    await transport.finishStream()
    #expect(try await GatewayTestValues.collect(replay).isEmpty)
    #expect(try await !client.shouldApply(terminal))
  }

  @Test
  func staleStartFailureCannotInvalidateAReplacementConnection() async throws {
    let transport = RecoveryTransport(suspendFirstStart: true)
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()
    let request = GatewayTestValues.request(runID: GatewayTestValues.runID(184))
    let oldStart = Task { try await client.startRun(request) }
    await transport.waitForPendingStart()
    _ = try await client.connect()
    await transport.failPendingStart()
    do {
      _ = try await oldStart.value
      Issue.record("Expected the old request to be superseded.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .supersededOperation)
    }
    #expect((try? await client.requireConnectedGeneration()) != nil)
    #expect(
      try await client.startRun(request).disposition
        == .alreadyRunning(invocationID: transport.invocationID))
  }

  @Test(arguments: [
    GatewayFailureCode.staleSession, .transportUnavailable, .disconnected, .notConnected,
  ])
  func failedAdmissionInvalidatesOnlyTheConnectionAndDoesNotRetryTheRun(
    code: GatewayFailureCode
  ) async throws {
    let transport = RecoveryTransport(startFailure: code)
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()
    let request = GatewayTestValues.request(runID: GatewayTestValues.runID(185))
    do {
      _ = try await client.startRun(request)
      Issue.record("Expected a synthetic transport failure after admission.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == code)
    }
    await expectDisconnected(client)
    #expect(await transport.startRequests == [request])
    #expect(await transport.admissionCount == 1)
  }

  private func expectDisconnected(_ client: HexGatewayClient) async {
    do {
      _ = try await client.requireConnectedGeneration()
      Issue.record("The failed transport left the client connected.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .notConnected)
    } catch {
      Issue.record("Expected notConnected, received \(error).")
    }
  }

  enum StreamLoss: CaseIterable, Sendable {
    case disconnected, unavailable, staleSession, notConnected, silentEnd

    var failureCode: GatewayFailureCode {
      switch self {
      case .disconnected: .disconnected
      case .unavailable: .transportUnavailable
      case .staleSession: .staleSession
      case .notConnected: .notConnected
      case .silentEnd: .producerEndedWithoutTerminalEvent
      }
    }
  }

  private actor RecoveryTransport: HexGatewayTransport {
    nonisolated let invocationID = GatewayTestValues.invocationID(181)
    private let instanceID = GatewayInstanceID()
    private var lease: GatewayTransportConnectionLease?
    private(set) var startRequests: [GatewayStartRunRequest] = []
    private(set) var admissionCount = 0
    private(set) var cursors: [GatewayEventCursor] = []
    private var streamContinuation:
      AsyncThrowingStream<GatewayEventEnvelope, any Error>.Continuation?
    private let startFailure: GatewayFailureCode?
    private let suspendFirstStart: Bool
    private var pendingStart: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(startFailure: GatewayFailureCode? = nil, suspendFirstStart: Bool = false) {
      self.startFailure = startFailure
      self.suspendFirstStart = suspendFirstStart
    }

    func handshake(_ request: GatewayHandshakeRequest, lease: GatewayTransportConnectionLease)
      async throws
      -> GatewayHandshakeResponse
    {
      self.lease = lease
      return GatewayHandshakeResponse(
        sessionID: GatewaySessionID(), gatewayInstanceID: instanceID,
        selectedVersion: .current, activeRun: nil)
    }

    func startRun(_ request: GatewayStartRunRequest, lease: GatewayTransportConnectionLease)
      async throws
      -> GatewayStartRunResponse
    {
      startRequests.append(request)
      let alreadyAdmitted = admissionCount > 0
      if !alreadyAdmitted { admissionCount += 1 }
      if suspendFirstStart, startRequests.count == 1 {
        await withCheckedContinuation { continuation in
          pendingStart = continuation
          for waiter in startWaiters { waiter.resume() }
          startWaiters.removeAll()
        }
        throw GatewayFailure(code: .transportUnavailable, message: "Old connection failed.")
      }
      if let startFailure {
        throw GatewayFailure(code: startFailure, message: "Admission response was lost.")
      }
      return GatewayStartRunResponse(
        runID: request.runID,
        disposition: alreadyAdmitted
          ? .alreadyRunning(invocationID: invocationID) : .started(invocationID: invocationID))
    }

    func cancelRun(_ request: GatewayCancelRunRequest, lease: GatewayTransportConnectionLease)
      async throws
      -> GatewayCancelRunResponse
    {
      GatewayCancelRunResponse(
        runID: request.runID, invocationID: request.invocationID, disposition: .requested)
    }

    func eventRecords(after cursor: GatewayEventCursor, lease: GatewayTransportConnectionLease)
      async throws
      -> AsyncThrowingStream<GatewayEventEnvelope, any Error>
    {
      cursors.append(cursor)
      let pair = AsyncThrowingStream<GatewayEventEnvelope, any Error>.makeStream()
      streamContinuation = pair.continuation
      return pair.stream
    }

    func disconnect(lease: GatewayTransportConnectionLease) async {
      if self.lease == lease { self.lease = nil }
    }

    func yield(_ envelope: GatewayEventEnvelope) { streamContinuation?.yield(envelope) }
    func finishStream() { streamContinuation?.finish() }
    func endStream(loss: StreamLoss) {
      if loss == .silentEnd {
        streamContinuation?.finish()
      } else {
        streamContinuation?.finish(
          throwing: GatewayFailure(code: loss.failureCode, message: "Stream was lost."))
      }
    }

    func waitForPendingStart() async {
      guard pendingStart == nil else { return }
      await withCheckedContinuation { startWaiters.append($0) }
    }

    func failPendingStart() {
      pendingStart?.resume()
      pendingStart = nil
    }
  }
}
