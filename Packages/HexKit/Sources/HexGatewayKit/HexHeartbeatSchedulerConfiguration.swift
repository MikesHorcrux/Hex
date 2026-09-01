import Foundation

public struct HexHeartbeatSchedulerConfiguration: Codable, Equatable, Sendable {
  public static let standard = HexHeartbeatSchedulerConfiguration(
    leaseDurationSeconds: 15 * 60,
    runTimeoutSeconds: 10 * 60,
    maximumSchedules: 64
  )

  public let leaseDurationSeconds: TimeInterval
  public let runTimeoutSeconds: TimeInterval
  public let maximumSchedules: Int

  public init(
    leaseDurationSeconds: TimeInterval = 15 * 60,
    runTimeoutSeconds: TimeInterval? = nil,
    maximumSchedules: Int = 64
  ) {
    self.leaseDurationSeconds = leaseDurationSeconds
    self.runTimeoutSeconds = runTimeoutSeconds ?? leaseDurationSeconds / 2
    self.maximumSchedules = maximumSchedules
  }

  func validated() throws -> Self {
    guard
      leaseDurationSeconds.isFinite,
      leaseDurationSeconds >= 1,
      leaseDurationSeconds <= 24 * 60 * 60,
      runTimeoutSeconds.isFinite,
      runTimeoutSeconds > 0,
      runTimeoutSeconds < leaseDurationSeconds,
      maximumSchedules > 0,
      maximumSchedules <= 256
    else {
      throw HexHeartbeatSchedulerError.invalidConfiguration(
        "Heartbeat run timeout must be positive and shorter than the lease; lease duration must be between one second and one day, and schedule capacity must be between 1 and 256."
      )
    }
    return self
  }
}
