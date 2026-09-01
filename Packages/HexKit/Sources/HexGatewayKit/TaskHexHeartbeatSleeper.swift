import Foundation

public struct TaskHexHeartbeatSleeper: HexHeartbeatSleeper, Sendable {
  public init() {}

  public func sleep(until date: Date?) async throws {
    if let date {
      let seconds = max(0, date.timeIntervalSince(Date()))
      guard seconds.isFinite else {
        try await Task.sleep(for: .hours(24))
        return
      }
      let requestedNanoseconds = seconds * 1_000_000_000
      let nanoseconds = requestedNanoseconds >= Double(UInt64.max)
        ? UInt64.max
        : UInt64(requestedNanoseconds.rounded(.up))
      try await Task.sleep(nanoseconds: nanoseconds)
    } else {
      // The scheduler cancels this sleep whenever a schedule is added or changed. The bounded
      // interval keeps the nil-schedule state cancellable even on platforms without an awaitable
      // notification primitive.
      try await Task.sleep(for: .hours(24))
    }
  }
}
