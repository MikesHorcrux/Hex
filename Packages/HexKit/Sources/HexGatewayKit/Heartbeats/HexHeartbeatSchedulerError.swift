import Foundation

public enum HexHeartbeatSchedulerError: Error, Equatable, LocalizedError, Sendable {
  case invalidConfiguration(String)
  case tooManySchedules
  case duplicateSchedule(HexHeartbeatScheduleID)
  case scheduleNotFound(HexHeartbeatScheduleID)
  case executionInProgress

  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration(let message):
      message
    case .tooManySchedules:
      "The heartbeat scheduler has reached its schedule limit."
    case .duplicateSchedule:
      "A heartbeat schedule with this identifier already exists."
    case .scheduleNotFound:
      "The heartbeat schedule was not found."
    case .executionInProgress:
      "A heartbeat execution is already in progress."
    }
  }
}
