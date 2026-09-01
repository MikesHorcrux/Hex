import Foundation

public struct HexHeartbeatSchedulerConfiguration: Codable, Equatable, Sendable {
  public static let standard = HexHeartbeatSchedulerConfiguration(
    leaseDurationSeconds: 15 * 60,
    maximumSchedules: 64
  )

  public let leaseDurationSeconds: TimeInterval
  public let maximumSchedules: Int

  public init(
    leaseDurationSeconds: TimeInterval = 15 * 60,
    maximumSchedules: Int = 64
  ) {
    self.leaseDurationSeconds = leaseDurationSeconds
    self.maximumSchedules = maximumSchedules
  }

  func validated() throws -> Self {
    guard
      leaseDurationSeconds.isFinite,
      leaseDurationSeconds >= 1,
      leaseDurationSeconds <= 24 * 60 * 60,
      maximumSchedules > 0,
      maximumSchedules <= 256
    else {
      throw HexHeartbeatSchedulerError.invalidConfiguration(
        "Heartbeat lease duration must be between one second and one day, and schedule capacity must be between 1 and 256."
      )
    }
    return self
  }
}
