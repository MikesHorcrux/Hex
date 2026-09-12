import Foundation
import HexCore
import HexIPC
import Testing

@Suite("Scheduled run history client boundary")
struct HeartbeatRunHistoryIPCTests {
  @Test(arguments: [false, true])
  func realClientDispatchesEveryScheduleMethodAndHistoryAcrossBothTransports(useXPC: Bool)
    async throws
  {
    let state = HandlerState()
    let driver = ControllableGatewayRunDriver()
    let gateway = HexGatewayService(driver: driver)
    let handlers = HexGatewayResidentControlHandlers(
      listHeartbeats: { await state.schedules(operation: "list") },
      addHeartbeat: { _ in await state.schedules(operation: "add") },
      removeHeartbeat: { _ in await state.schedules(operation: "remove") },
      pauseHeartbeat: { _ in await state.schedules(operation: "pause") },
      resumeHeartbeat: { _ in await state.schedules(operation: "resume") },
      listHeartbeatRuns: { request in try await state.history(request) })
    let transport: any HexGatewayTransport
    if useXPC {
      transport = XPCGatewayTransport(
        connectionFactory: ConnectionFactory(
          connection: Connection(gateway: gateway, handlers: handlers)))
    } else {
      transport = InProcessHexGatewayTransport(service: gateway, residentControlHandlers: handlers)
    }
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()
    let schedule = Self.schedule
    #expect(try await client.listHeartbeats().schedules == [schedule])
    _ = try await client.addHeartbeat(
      GatewayHeartbeatScheduleRequest(
        id: schedule.id, name: schedule.name, instruction: schedule.instruction,
        intervalSeconds: schedule.intervalSeconds, nextDueAt: schedule.nextDueAt))
    let mutation = GatewayHeartbeatScheduleMutation(scheduleID: schedule.id)
    _ = try await client.pauseHeartbeat(mutation)
    _ = try await client.resumeHeartbeat(mutation)
    _ = try await client.removeHeartbeat(mutation)
    let first = try await client.listHeartbeatRuns(GatewayHeartbeatRunListRequest(limit: 1))
    #expect(first.runs == [Self.receipt])
    #expect(first.runs[0].journal?.firstEventID == Self.firstEventID)
    let next = try #require(first.nextCursor)
    let last = try await client.listHeartbeatRuns(
      GatewayHeartbeatRunListRequest(cursor: next, limit: 1))
    #expect(last.storeID == first.storeID)
    #expect(last.runs.count == 1)
    #expect(last.runs[0].runID == nil)
    #expect(last.nextCursor == nil)
    #expect(
      await state.operations == ["list", "add", "pause", "resume", "remove", "history", "history"])
    #expect(await driver.invocationCount(for: Self.runID) == 0)
    try await client.disconnect()
  }

  @Test
  func olderPeerWithoutAcknowledgedEventsFailsBeforeAnyScheduleOperation()
    async throws
  {
    let state = HandlerState()
    let transport = InProcessHexGatewayTransport(
      service: HexGatewayService(driver: ImmediateGatewayRunDriver()),
      residentControlHandlers: HexGatewayResidentControlHandlers(
        listHeartbeats: { await state.schedules(operation: "list") },
        listHeartbeatRuns: { try await state.history($0) }))
    let client = HexGatewayClient(
      transport: transport,
      minimumVersion: GatewayProtocolVersion(major: 1, minor: 10),
      maximumVersion: GatewayProtocolVersion(major: 1, minor: 10))
    do {
      _ = try await client.connect()
      Issue.record("A peer lacking acknowledged event delivery must not complete handshake.")
    } catch let failure as GatewayFailure { #expect(failure.code == .incompatibleProtocolVersion) }
    #expect(await state.operations.isEmpty)
  }

  @Test
  func receiptValidationRejectsChangedScopeStoreDuplicateAndUnboundedMetadata() throws {
    let cursor = GatewayHeartbeatRunCursor(
      storeID: Self.storeID, scheduleID: Self.schedule.id,
      highWaterSequence: 5, beforeSequence: 4)
    #expect(throws: GatewayFailure.self) {
      try GatewayHeartbeatRunListRequest(cursor: cursor).validated()
    }
    let request = GatewayHeartbeatRunListRequest(scheduleID: Self.schedule.id, cursor: cursor)
    #expect(throws: GatewayFailure.self) {
      try GatewayHeartbeatRunPage(storeID: UUID(), runs: [Self.receipt]).validated(for: request)
    }
    #expect(throws: GatewayFailure.self) {
      try GatewayHeartbeatRunPage(storeID: Self.storeID, runs: [Self.receipt, Self.receipt])
        .validated()
    }
    #expect(throws: GatewayFailure.self) {
      try GatewayHeartbeatRunPage(storeID: Self.storeID, runs: [], nextCursor: cursor).validated()
    }
    #expect(throws: GatewayFailure.self) {
      try GatewayHeartbeatRunListRequest(limit: 65).validated()
    }
    #expect(throws: GatewayFailure.self) {
      try GatewayHeartbeatRun(
        scheduleID: Self.schedule.id, dueAt: Self.now,
        scheduleName: String(repeating: "x", count: 513)
      ).validated()
    }
    #expect(throws: GatewayFailure.self) {
      try GatewayHeartbeatRun(
        scheduleID: Self.schedule.id, dueAt: Self.now, scheduleName: "Check",
        runID: AgentRunID(), outcome: Self.receipt.outcome, journal: Self.receipt.journal
      ).validated()
    }
    #expect(throws: GatewayFailure.self) {
      try GatewayHeartbeatRunPage(storeID: Self.storeID, runs: [Self.receipt], nextCursor: cursor)
        .validated(for: request)
    }
    #expect(
      try GatewayHeartbeatRunPage(storeID: Self.storeID, runs: [Self.receipt]).validated(
        for: request
      ).runs.count == 1)
  }

  @Test(arguments: [false, true])
  func fullyEncodedResponseBudgetFailsWithoutSilentlyDroppingReceiptRows(useXPC: Bool) async throws
  {
    let configuration = try #require(
      GatewayConfiguration(
        maximumWireBytes: 2_048,
        maximumRetainedRecordsPerRun: 1, subscriberBufferCapacity: 1))
    let large = GatewayHeartbeatRun(
      scheduleID: Self.schedule.id, dueAt: Self.now, scheduleName: "Check",
      outcome: GatewayHeartbeatOutcome(
        kind: .failed, completedAt: Self.now,
        failureMessage: String(repeating: "x", count: 4_096)))
    let handlers = HexGatewayResidentControlHandlers(listHeartbeatRuns: { _ in
      GatewayHeartbeatRunPage(storeID: Self.storeID, runs: [large])
    })
    let gateway = HexGatewayService(
      driver: ImmediateGatewayRunDriver(), configuration: configuration)
    let transport: any HexGatewayTransport
    if useXPC {
      transport = XPCGatewayTransport(
        connectionFactory: ConnectionFactory(
          connection: Connection(gateway: gateway, handlers: handlers, configuration: configuration)
        ),
        configuration: configuration)
    } else {
      transport = InProcessHexGatewayTransport(
        service: gateway, configuration: configuration,
        residentControlHandlers: handlers)
    }
    let client = HexGatewayClient(transport: transport, configuration: configuration)
    _ = try await client.connect()
    do {
      _ = try await client.listHeartbeatRuns(GatewayHeartbeatRunListRequest())
      Issue.record("An oversized receipt must not become an empty successful page.")
    } catch let failure as GatewayFailure { #expect(failure.code == .payloadTooLarge) }
    try await client.disconnect()
  }

  @Test
  func readStartedOnOldConnectionCannotReturnAfterDisconnect() async throws {
    let gate = ReadGate()
    let transport = InProcessHexGatewayTransport(
      service: HexGatewayService(driver: ImmediateGatewayRunDriver()),
      residentControlHandlers: HexGatewayResidentControlHandlers(listHeartbeatRuns: { _ in
        await gate.read()
        return GatewayHeartbeatRunPage(storeID: Self.storeID, runs: [Self.receipt])
      }))
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()
    let pending = Task { try await client.listHeartbeatRuns(GatewayHeartbeatRunListRequest()) }
    await gate.waitUntilEntered()
    try await client.disconnect()
    await gate.release()
    do {
      _ = try await pending.value
      Issue.record("An old connection returned a scheduled-run page after disconnect.")
    } catch let failure as GatewayFailure {
      #expect(
        [GatewayFailureCode.notConnected, .disconnected, .supersededOperation].contains(
          failure.code))
    }
  }

  @Test
  func publicJournalValidatorsPreserveNativeRecordsAndRejectWrongRunAndGap() throws {
    let start = GatewayTestValues.record(runID: Self.runID, sequence: 1, event: .runStarted)
    let end = GatewayTestValues.record(runID: Self.runID, sequence: 2, event: .runCompleted)
    let instance = GatewayInstanceID()
    let request = GatewayRunHistoryRequest(
      runID: Self.runID, firstEventID: start.id,
      afterSequence: 0, throughSequence: 2)
    let page = GatewayRunHistoryPage(
      gatewayInstanceID: instance, runID: Self.runID,
      firstEventID: start.id, afterSequence: 0, throughSequence: 2,
      records: [start, end], nextAfterSequence: nil)
    #expect(try page.validated(for: request) == page)
    let recovery = GatewayRunRecoveryResponse(
      gatewayInstanceID: instance, runID: Self.runID,
      disposition: .journaled(
        GatewayJournalRunSnapshot(
          runID: Self.runID, firstEventID: start.id,
          latestSequence: 2, terminalRecord: end)))
    #expect(try recovery.validated(for: GatewayRunRecoveryRequest(runID: Self.runID)) == recovery)
    #expect(throws: GatewayFailure.self) {
      try recovery.validated(for: GatewayRunRecoveryRequest(runID: AgentRunID()))
    }
    #expect(throws: GatewayFailure.self) {
      try GatewayRunHistoryPage(
        gatewayInstanceID: instance, runID: Self.runID, firstEventID: start.id,
        afterSequence: 0, throughSequence: 2, records: [end], nextAfterSequence: nil
      ).validated(for: request)
    }
  }

  private static let storeID = GatewayTestValues.uuid(201)
  private static let runID = GatewayTestValues.runID(202)
  private static let firstEventID = AgentEventID(rawValue: GatewayTestValues.uuid(203))
  private static let now = Date(timeIntervalSince1970: 1_700_000_000)
  private static var schedule: GatewayHeartbeatSchedule {
    GatewayHeartbeatSchedule(
      id: GatewayTestValues.uuid(204), name: "Morning check",
      instruction: "Read the project status.", intervalSeconds: 3600, nextDueAt: now,
      maxCatchUpOccurrences: 1, isPaused: false)
  }
  private static var receipt: GatewayHeartbeatRun {
    GatewayHeartbeatRun(
      scheduleID: schedule.id, dueAt: now, scheduleName: schedule.name, runID: runID,
      claimedAt: now, expiresAt: now.addingTimeInterval(900),
      outcome: GatewayHeartbeatOutcome(kind: .succeeded, completedAt: now.addingTimeInterval(1)),
      journal: GatewayHeartbeatRunJournalIdentity(
        runID: runID, firstEventID: firstEventID, terminalSequence: 4))
  }

  private actor HandlerState {
    var operations: [String] = []
    func schedules(operation: String) -> GatewayHeartbeatScheduleList {
      operations.append(operation)
      return GatewayHeartbeatScheduleList(schedules: [HeartbeatRunHistoryIPCTests.schedule])
    }
    func history(_ request: GatewayHeartbeatRunListRequest) throws -> GatewayHeartbeatRunPage {
      operations.append("history")
      _ = try request.validated()
      if request.cursor == nil {
        return GatewayHeartbeatRunPage(
          storeID: HeartbeatRunHistoryIPCTests.storeID,
          runs: [HeartbeatRunHistoryIPCTests.receipt],
          nextCursor: GatewayHeartbeatRunCursor(
            storeID: HeartbeatRunHistoryIPCTests.storeID, scheduleID: request.scheduleID,
            highWaterSequence: 2, beforeSequence: 2))
      }
      return GatewayHeartbeatRunPage(
        storeID: HeartbeatRunHistoryIPCTests.storeID,
        runs: [
          GatewayHeartbeatRun(
            scheduleID: HeartbeatRunHistoryIPCTests.schedule.id,
            dueAt: HeartbeatRunHistoryIPCTests.now.addingTimeInterval(-3600),
            scheduleName: "Old name",
            outcome: GatewayHeartbeatOutcome(
              kind: .interrupted, completedAt: HeartbeatRunHistoryIPCTests.now))
        ])
    }
  }

  private actor Connection: HexGatewayXPCConnection {
    private let service: HexGatewayXPCService
    init(
      gateway: HexGatewayService, handlers: HexGatewayResidentControlHandlers,
      configuration: GatewayConfiguration = .standard
    ) {
      service = HexGatewayXPCService(
        service: gateway, configuration: configuration,
        residentControlHandlers: handlers)
    }
    func request(_ envelope: Data) async throws -> Data {
      await withCheckedContinuation { continuation in
        service.request(envelope) { continuation.resume(returning: $0) }
      }
    }
    func subscribe(_ envelope: Data, bufferCapacity: Int) async throws
      -> GatewayXPCEventSubscription
    {
      throw GatewayFailure(
        code: .transportUnavailable, message: "History must not subscribe to live events.")
    }
    func cancelSubscription(_ envelope: Data) async {}
    func invalidate() async { service.invalidate() }
  }

  private struct ConnectionFactory: HexGatewayXPCConnectionFactory {
    let connection: Connection
    func makeConnection() -> any HexGatewayXPCConnection { connection }
  }

  private actor ReadGate {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func read() async {
      entered = true
      entryWaiter?.resume()
      entryWaiter = nil
      await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitUntilEntered() async {
      if entered { return }
      await withCheckedContinuation { entryWaiter = $0 }
    }
    func release() {
      releaseWaiter?.resume()
      releaseWaiter = nil
    }
  }
}
