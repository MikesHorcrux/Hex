import Foundation
import HexCore
import HexIPC
import Testing

@Suite("Heartbeat schedule management IPC")
struct HeartbeatScheduleIPCTests {
  @Test
  func boundedContractsRoundTripAndRejectOversizedValues() throws {
    let codec = GatewayWireCodec(configuration: .standard)
    let request = GatewayHeartbeatScheduleRequest(
      id: GatewayTestValues.uuid(231),
      name: "Morning check-in",
      instruction: "Review the day and suggest one useful next step.",
      intervalSeconds: 60 * 60,
      nextDueAt: Date(timeIntervalSince1970: 1_700_000_000),
      maxCatchUpOccurrences: 2
    )

    let encodedRequest = try codec.encode(request)
    #expect(encodedRequest.count <= GatewayConfiguration.standard.maximumWireBytes)
    #expect(try codec.roundTrip(request) == request)

    let oversized = GatewayHeartbeatScheduleRequest(
      id: GatewayTestValues.uuid(232),
      name: "Valid name",
      instruction: String(
        repeating: "x", count: GatewayHeartbeatSchedule.maximumInstructionBytes + 1),
      intervalSeconds: 60,
      nextDueAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    do {
      _ = try oversized.validated()
      Issue.record("Expected an oversized heartbeat instruction to fail validation.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .malformedPayload)
    }
  }

  @Test
  func xpcServiceSupportsListAddRemovePauseAndResume() async throws {
    let state = HeartbeatHandlerState(
      schedules: GatewayHeartbeatScheduleList(
        schedules: [Self.schedule(id: GatewayTestValues.uuid(233))]
      )
    )
    let handlers = HexGatewayResidentControlHandlers(
      listHeartbeats: { try await state.list() },
      addHeartbeat: { request in try await state.add(request) },
      removeHeartbeat: { mutation in try await state.remove(mutation) },
      pauseHeartbeat: { mutation in try await state.pause(mutation) },
      resumeHeartbeat: { mutation in try await state.resume(mutation) }
    )
    let exportedService = HexGatewayXPCService(
      service: HexGatewayService(driver: ImmediateGatewayRunDriver()),
      residentControlHandlers: handlers
    )
    let codec = GatewayWireCodec(configuration: .standard)
    let lease = GatewayTransportConnectionLease(rawValue: GatewayTestValues.uuid(234))
    let handshake = try await sendHandshake(
      lease: lease,
      service: exportedService,
      codec: codec
    )

    let listed = try await sendScheduleOperation(
      operation: .listHeartbeats,
      lease: lease,
      sessionID: handshake.sessionID,
      body: Data(),
      service: exportedService,
      codec: codec
    )
    #expect(listed.schedules.count == 1)

    let addRequest = GatewayHeartbeatScheduleRequest(
      id: GatewayTestValues.uuid(235),
      name: "Evening check-in",
      instruction: "Summarize anything that should be carried into tomorrow.",
      intervalSeconds: 2 * 60 * 60,
      nextDueAt: Date(timeIntervalSince1970: 1_700_000_100)
    )
    let added = try await sendScheduleOperation(
      operation: .addHeartbeat,
      lease: lease,
      sessionID: handshake.sessionID,
      body: try codec.encode(addRequest),
      service: exportedService,
      codec: codec
    )
    #expect(added.schedules.count == 2)
    #expect(added.schedules.contains { $0.id == addRequest.id })

    let mutation = GatewayHeartbeatScheduleMutation(scheduleID: addRequest.id)
    let paused = try await sendScheduleOperation(
      operation: .pauseHeartbeat,
      lease: lease,
      sessionID: handshake.sessionID,
      body: try codec.encode(mutation),
      service: exportedService,
      codec: codec
    )
    #expect(paused.schedules.first { $0.id == addRequest.id }?.isPaused == true)

    let resumed = try await sendScheduleOperation(
      operation: .resumeHeartbeat,
      lease: lease,
      sessionID: handshake.sessionID,
      body: try codec.encode(mutation),
      service: exportedService,
      codec: codec
    )
    #expect(resumed.schedules.first { $0.id == addRequest.id }?.isPaused == false)

    let removed = try await sendScheduleOperation(
      operation: .removeHeartbeat,
      lease: lease,
      sessionID: handshake.sessionID,
      body: try codec.encode(mutation),
      service: exportedService,
      codec: codec
    )
    #expect(removed.schedules.count == 1)
    #expect(!removed.schedules.contains { $0.id == addRequest.id })
  }

  @Test
  func malformedScheduleMutationFailsBeforeHandlerAndMissingCapabilityFailsClosed() async throws {
    let state = HeartbeatHandlerState(schedules: GatewayHeartbeatScheduleList())
    let handlers = HexGatewayResidentControlHandlers(
      addHeartbeat: { request in try await state.add(request) },
      removeHeartbeat: { mutation in try await state.remove(mutation) }
    )
    let exportedService = HexGatewayXPCService(
      service: HexGatewayService(driver: ImmediateGatewayRunDriver()),
      residentControlHandlers: handlers
    )
    let codec = GatewayWireCodec(configuration: .standard)
    let lease = GatewayTransportConnectionLease(rawValue: GatewayTestValues.uuid(236))
    let handshake = try await sendHandshake(
      lease: lease,
      service: exportedService,
      codec: codec
    )

    let invalidMutation = GatewayHeartbeatScheduleMutation(
      scheduleID: GatewayHeartbeatSchedule.zeroUUID)
    let invalidResponse = try await sendRawScheduleOperation(
      operation: .removeHeartbeat,
      lease: lease,
      sessionID: handshake.sessionID,
      body: try codec.encode(invalidMutation),
      service: exportedService,
      codec: codec
    )
    #expect(invalidResponse.failure?.code == .malformedPayload)

    let missingListResponse = try await sendRawScheduleOperation(
      operation: .listHeartbeats,
      lease: lease,
      sessionID: handshake.sessionID,
      body: Data(),
      service: exportedService,
      codec: codec
    )
    #expect(missingListResponse.failure?.code == .transportUnavailable)
    #expect(await state.addCallCount == 0)
  }

  private static func schedule(id: UUID) -> GatewayHeartbeatSchedule {
    GatewayHeartbeatSchedule(
      id: id,
      name: "Check-in",
      instruction: "Review the current context.",
      intervalSeconds: 60 * 60,
      nextDueAt: Date(timeIntervalSince1970: 1_700_000_000),
      maxCatchUpOccurrences: 1,
      isPaused: false
    )
  }

  private actor HeartbeatHandlerState {
    private var scheduleList: GatewayHeartbeatScheduleList
    private(set) var addCallCount = 0

    init(schedules: GatewayHeartbeatScheduleList) {
      scheduleList = schedules
    }

    func list() throws -> GatewayHeartbeatScheduleList {
      try scheduleList.validated()
    }

    func add(_ request: GatewayHeartbeatScheduleRequest) throws -> GatewayHeartbeatScheduleList {
      addCallCount += 1
      let request = try request.validated()
      let schedule = GatewayHeartbeatSchedule(
        id: request.id,
        name: request.name,
        instruction: request.instruction,
        intervalSeconds: request.intervalSeconds,
        nextDueAt: request.nextDueAt,
        maxCatchUpOccurrences: request.maxCatchUpOccurrences,
        isPaused: request.isPaused
      )
      scheduleList = GatewayHeartbeatScheduleList(
        schedules: scheduleList.schedules + [schedule],
        isPaused: scheduleList.isPaused
      )
      return try scheduleList.validated()
    }

    func remove(_ mutation: GatewayHeartbeatScheduleMutation) throws -> GatewayHeartbeatScheduleList
    {
      let mutation = try mutation.validated()
      scheduleList = GatewayHeartbeatScheduleList(
        schedules: scheduleList.schedules.filter { $0.id != mutation.scheduleID },
        isPaused: scheduleList.isPaused
      )
      return try scheduleList.validated()
    }

    func pause(_ mutation: GatewayHeartbeatScheduleMutation) throws -> GatewayHeartbeatScheduleList
    {
      try setPaused(true, mutation: mutation)
    }

    func resume(_ mutation: GatewayHeartbeatScheduleMutation) throws -> GatewayHeartbeatScheduleList
    {
      try setPaused(false, mutation: mutation)
    }

    private func setPaused(
      _ isPaused: Bool,
      mutation: GatewayHeartbeatScheduleMutation
    ) throws -> GatewayHeartbeatScheduleList {
      let mutation = try mutation.validated()
      scheduleList = GatewayHeartbeatScheduleList(
        schedules: scheduleList.schedules.map { schedule in
          guard schedule.id == mutation.scheduleID else { return schedule }
          return GatewayHeartbeatSchedule(
            id: schedule.id,
            name: schedule.name,
            instruction: schedule.instruction,
            intervalSeconds: schedule.intervalSeconds,
            nextDueAt: schedule.nextDueAt,
            maxCatchUpOccurrences: schedule.maxCatchUpOccurrences,
            isPaused: isPaused,
            lastOutcome: schedule.lastOutcome
          )
        },
        isPaused: scheduleList.isPaused
      )
      return try scheduleList.validated()
    }
  }

  private func sendHandshake(
    lease: GatewayTransportConnectionLease,
    service: HexGatewayXPCService,
    codec: GatewayWireCodec
  ) async throws -> GatewayHandshakeResponse {
    let request = GatewayTestValues.handshakeRequest(237)
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

  private func sendScheduleOperation(
    operation: GatewayXPCOperation,
    lease: GatewayTransportConnectionLease,
    sessionID: GatewaySessionID,
    body: Data,
    service: HexGatewayXPCService,
    codec: GatewayWireCodec
  ) async throws -> GatewayHeartbeatScheduleList {
    let response = try await sendRawScheduleOperation(
      operation: operation,
      lease: lease,
      sessionID: sessionID,
      body: body,
      service: service,
      codec: codec
    )
    guard let responseBody = response.body else {
      throw response.failure
        ?? GatewayFailure(
          code: .malformedPayload,
          message: "The test response did not contain a heartbeat schedule list."
        )
    }
    return try codec.decode(GatewayHeartbeatScheduleList.self, from: responseBody).validated()
  }

  private func sendRawScheduleOperation(
    operation: GatewayXPCOperation,
    lease: GatewayTransportConnectionLease,
    sessionID: GatewaySessionID,
    body: Data,
    service: HexGatewayXPCService,
    codec: GatewayWireCodec
  ) async throws -> GatewayXPCResponseEnvelope {
    let envelope = try codec.encode(
      GatewayXPCRequestEnvelope(
        operation: operation,
        lease: lease,
        sessionID: sessionID,
        body: body
      )
    )
    let rawResponse = try await sendRequest(envelope, to: service)
    return try codec.decode(GatewayXPCResponseEnvelope.self, from: rawResponse).validated()
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
}
