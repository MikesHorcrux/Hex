import Foundation
import HexIPC
import Testing

@testable import Hex

@Suite("Heartbeat management")
struct HexHeartbeatManagementTests {
  @Test @MainActor
  func refreshAndMutationsKeepTheResidentProjectionAuthoritative() async {
    let existingID = UUID()
    let service = FakeHeartbeatService(schedules: [Self.schedule(id: existingID)])
    let model = HexHeartbeatManagementModel(service: service)

    await model.refresh()

    #expect(model.schedules.count == 1)
    #expect(model.schedules.first?.id == existingID)
    #expect(model.canAddSchedule)

    let addedID = UUID()
    let request = GatewayHeartbeatScheduleRequest(
      id: addedID,
      name: "Evening check-in",
      instruction: "Summarize anything to carry into tomorrow.",
      intervalSeconds: 2 * 60 * 60,
      nextDueAt: Date(timeIntervalSince1970: 1_700_000_100)
    )
    #expect(await model.addSchedule(request))
    #expect(model.schedules.contains { $0.id == addedID })

    #expect(await model.pauseSchedule(id: addedID))
    #expect(model.schedules.first { $0.id == addedID }?.isPaused == true)

    #expect(await model.resumeSchedule(id: addedID))
    #expect(model.schedules.first { $0.id == addedID }?.isPaused == false)

    #expect(await model.removeSchedule(id: addedID))
    #expect(!model.schedules.contains { $0.id == addedID })
  }

  @Test @MainActor
  func malformedResidentProjectionFailsClosed() async {
    let existing = Self.schedule(id: UUID())
    let service = FakeHeartbeatService(schedules: [existing], returnsMalformedList: true)
    let model = HexHeartbeatManagementModel(service: service)

    await model.refresh()

    #expect(model.schedules.isEmpty)
    #expect(
      model.message == "The resident gateway returned duplicate heartbeat schedule identities.")
  }

  @Test @MainActor
  func unavailableServiceSurfacesAUserActionableMessage() async {
    let model = HexHeartbeatManagementModel()

    await model.refresh()

    #expect(model.schedules.isEmpty)
    #expect(
      model.message
        == "Heartbeat schedules are unavailable until the resident gateway is connected.")
    #expect(!model.canAddSchedule)
  }

  private static func schedule(id: UUID) -> GatewayHeartbeatSchedule {
    GatewayHeartbeatSchedule(
      id: id,
      name: "Morning check-in",
      instruction: "Review the day and suggest one useful next step.",
      intervalSeconds: 60 * 60,
      nextDueAt: Date(timeIntervalSince1970: 1_700_000_000),
      maxCatchUpOccurrences: 1,
      isPaused: false
    )
  }

  private actor FakeHeartbeatService: HexHeartbeatManaging {
    private var schedules: [GatewayHeartbeatSchedule]
    private let returnsMalformedList: Bool

    init(
      schedules: [GatewayHeartbeatSchedule],
      returnsMalformedList: Bool = false
    ) {
      self.schedules = schedules
      self.returnsMalformedList = returnsMalformedList
    }

    func listHeartbeatSchedules() async throws -> GatewayHeartbeatScheduleList {
      try response().validated()
    }

    func addHeartbeatSchedule(
      _ request: GatewayHeartbeatScheduleRequest
    ) async throws -> GatewayHeartbeatScheduleList {
      let request = try request.validated()
      schedules.append(
        GatewayHeartbeatSchedule(
          id: request.id,
          name: request.name,
          instruction: request.instruction,
          intervalSeconds: request.intervalSeconds,
          nextDueAt: request.nextDueAt,
          maxCatchUpOccurrences: request.maxCatchUpOccurrences,
          isPaused: request.isPaused
        )
      )
      return try response().validated()
    }

    func removeHeartbeatSchedule(
      _ mutation: GatewayHeartbeatScheduleMutation
    ) async throws -> GatewayHeartbeatScheduleList {
      let mutation = try mutation.validated()
      schedules.removeAll { $0.id == mutation.scheduleID }
      return try response().validated()
    }

    func pauseHeartbeatSchedule(
      _ mutation: GatewayHeartbeatScheduleMutation
    ) async throws -> GatewayHeartbeatScheduleList {
      try setPaused(true, mutation: mutation)
    }

    func resumeHeartbeatSchedule(
      _ mutation: GatewayHeartbeatScheduleMutation
    ) async throws -> GatewayHeartbeatScheduleList {
      try setPaused(false, mutation: mutation)
    }

    private func setPaused(
      _ isPaused: Bool,
      mutation: GatewayHeartbeatScheduleMutation
    ) throws -> GatewayHeartbeatScheduleList {
      let mutation = try mutation.validated()
      schedules = schedules.map { schedule in
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
      }
      return try response().validated()
    }

    private func response() throws -> GatewayHeartbeatScheduleList {
      if returnsMalformedList, let first = schedules.first {
        return GatewayHeartbeatScheduleList(schedules: [first, first])
      }
      return GatewayHeartbeatScheduleList(schedules: schedules)
    }
  }
}
