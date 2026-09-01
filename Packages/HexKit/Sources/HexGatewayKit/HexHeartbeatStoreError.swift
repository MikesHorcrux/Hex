import Foundation

public enum HexHeartbeatStoreError: Error, Equatable, LocalizedError, Sendable {
  case invalidSchedule(String)
  case invalidSnapshot(String)
  case invalidLease(String)
  case scheduleNotFound(HexHeartbeatScheduleID)
  case staleLease
  case invalidCompletion(String)
  case ioFailure
  case encodingFailure

  public var errorDescription: String? {
    switch self {
    case .invalidSchedule(let message), .invalidSnapshot(let message),
      .invalidLease(let message), .invalidCompletion(let message):
      message
    case .scheduleNotFound:
      "The heartbeat schedule was not found."
    case .staleLease:
      "The heartbeat completion used a stale or already-finished lease."
    case .ioFailure:
      "The heartbeat store could not durably replace its file."
    case .encodingFailure:
      "The heartbeat store could not encode its durable snapshot."
    }
  }
}
