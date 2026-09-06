import Foundation
import HexIPC
import Observation

@MainActor
@Observable
final class HexHeartbeatManagementModel {
  private(set) var schedules: [GatewayHeartbeatSchedule] = []
  private(set) var isPaused = false
  private(set) var isAvailable = false
  private(set) var isLoading = false
  private(set) var isMutating = false
  private(set) var message: String?

  private let service: any HexHeartbeatManaging
  let history: HexHeartbeatRunHistoryModel

  init(
    service: any HexHeartbeatManaging = HexUnavailableHeartbeatService(),
    client: any HexAgentClient = PreviewHexAgentClient()
  ) {
    self.service = service
    history = HexHeartbeatRunHistoryModel(service: service, client: client)
  }

  var isBusy: Bool {
    isLoading || isMutating
  }

  var canAddSchedule: Bool {
    isAvailable && !isBusy && schedules.count < GatewayHeartbeatScheduleList.maximumSchedules
  }

  var scheduleLimitMessage: String? {
    schedules.count >= GatewayHeartbeatScheduleList.maximumSchedules
      ? "Hex supports up to \(GatewayHeartbeatScheduleList.maximumSchedules) heartbeat schedules."
      : nil
  }

  func refresh() async {
    guard !isBusy else { return }
    isLoading = true
    message = nil
    defer { isLoading = false }

    do {
      let response = try await service.listHeartbeatSchedules()
      try apply(response)
    } catch is CancellationError {
      return
    } catch {
      isAvailable = false
      message = error.localizedDescription
    }
  }

  @discardableResult
  func addSchedule(_ request: GatewayHeartbeatScheduleRequest) async -> Bool {
    await performMutation {
      try await service.addHeartbeatSchedule(request)
    }
  }

  @discardableResult
  func removeSchedule(id: UUID) async -> Bool {
    await performMutation {
      try await service.removeHeartbeatSchedule(
        GatewayHeartbeatScheduleMutation(scheduleID: id)
      )
    }
  }

  @discardableResult
  func pauseSchedule(id: UUID) async -> Bool {
    await performMutation {
      try await service.pauseHeartbeatSchedule(
        GatewayHeartbeatScheduleMutation(scheduleID: id)
      )
    }
  }

  @discardableResult
  func resumeSchedule(id: UUID) async -> Bool {
    await performMutation {
      try await service.resumeHeartbeatSchedule(
        GatewayHeartbeatScheduleMutation(scheduleID: id)
      )
    }
  }

  @discardableResult
  func togglePause(for schedule: GatewayHeartbeatSchedule) async -> Bool {
    if schedule.isPaused {
      return await resumeSchedule(id: schedule.id)
    }
    return await pauseSchedule(id: schedule.id)
  }

  func dismissMessage() {
    message = nil
  }

  private func performMutation(
    _ operation: () async throws -> GatewayHeartbeatScheduleList
  ) async -> Bool {
    guard !isBusy else { return false }
    isMutating = true
    message = nil
    defer { isMutating = false }

    do {
      let response = try await operation()
      try apply(response)
      return true
    } catch is CancellationError {
      return false
    } catch {
      message = error.localizedDescription
      return false
    }
  }

  private func apply(_ response: GatewayHeartbeatScheduleList) throws {
    let validated = try response.validated()
    schedules = validated.schedules.sorted { lhs, rhs in
      let comparison = lhs.name.localizedStandardCompare(rhs.name)
      if comparison != .orderedSame {
        return comparison == .orderedAscending
      }
      return lhs.id.uuidString < rhs.id.uuidString
    }
    isPaused = validated.isPaused
    isAvailable = true
  }
}
