import Foundation
import HexIPC

enum HexUnavailableHeartbeatServiceError: Error, Equatable, LocalizedError, Sendable {
  case unavailable

  var errorDescription: String? {
    "Heartbeat schedules are unavailable until the resident gateway is connected."
  }
}
