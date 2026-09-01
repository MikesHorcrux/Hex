public struct GatewayConfiguration: Equatable, Sendable {
  /// The standard wire envelope reserves one MiB beyond HexRuntime's standard 7,340,032-byte
  /// journal-event budget for `GatewayEventEnvelope` metadata and JSON framing. HexIPC intentionally
  /// does not depend on HexRuntime, so integration must keep these two documented budgets aligned.
  ///
  /// Replay retains at most eight records and 32 MiB per run. With four remembered runs, two live
  /// subscribers, and the same-process transport's second bounded forwarding buffer, the standard
  /// theoretical retained-plus-buffered wire payload is 384 MiB. A reconnect older than either the
  /// eight-record or 32-MiB per-run replay window fails explicitly with `replayUnavailable`.
  public static var standard: GatewayConfiguration {
    GatewayConfiguration(
      validatedMaximumWireBytes: 8_388_608,
      validatedMaximumRetainedRecordsPerRun: 8,
      validatedMaximumRetainedWireBytesPerRun: 33_554_432,
      validatedSubscriberBufferCapacity: 8,
      validatedMaximumSubscribersPerRun: 2,
      validatedMaximumSessions: 8,
      validatedMaximumRememberedRuns: 4
    )
  }

  private static let hardMaximumWireBytes = 16_777_216
  private static let hardMaximumRetainedRecordsPerRun = 256
  private static let hardMaximumRetainedWireBytesPerRun = 134_217_728
  private static let hardMaximumSubscriberBufferCapacity = 256
  private static let hardMaximumSubscribersPerRun = 4
  private static let hardMaximumSessions = 64
  private static let hardMaximumRememberedRuns = 128
  private static let hardMaximumBufferedWireBytesPerSubscriber = 67_108_864
  private static let hardMaximumBufferedWireBytesAcrossSubscribers = 134_217_728
  private static let hardMaximumRetainedWireBytesAcrossRuns = 134_217_728

  public let maximumWireBytes: Int
  public let maximumRetainedRecordsPerRun: Int
  public let maximumRetainedWireBytesPerRun: Int
  public let subscriberBufferCapacity: Int
  public let maximumSubscribersPerRun: Int
  public let maximumSessions: Int
  public let maximumRememberedRuns: Int

  public init?(
    maximumWireBytes: Int,
    maximumRetainedRecordsPerRun: Int,
    maximumRetainedWireBytesPerRun: Int = 33_554_432,
    subscriberBufferCapacity: Int,
    maximumSubscribersPerRun: Int = 2,
    maximumSessions: Int = 8,
    maximumRememberedRuns: Int = 4
  ) {
    guard
      maximumWireBytes > 0,
      maximumWireBytes <= Self.hardMaximumWireBytes,
      maximumRetainedRecordsPerRun > 0,
      maximumRetainedRecordsPerRun <= Self.hardMaximumRetainedRecordsPerRun,
      maximumRetainedWireBytesPerRun >= maximumWireBytes,
      maximumRetainedWireBytesPerRun <= Self.hardMaximumRetainedWireBytesPerRun,
      subscriberBufferCapacity >= maximumRetainedRecordsPerRun,
      subscriberBufferCapacity <= Self.hardMaximumSubscriberBufferCapacity,
      maximumSubscribersPerRun > 0,
      maximumSubscribersPerRun <= Self.hardMaximumSubscribersPerRun,
      maximumSessions > 0,
      maximumSessions <= Self.hardMaximumSessions,
      maximumRememberedRuns > 0,
      maximumRememberedRuns <= Self.hardMaximumRememberedRuns,
      maximumWireBytes
        <= Self.hardMaximumBufferedWireBytesPerSubscriber / subscriberBufferCapacity
    else {
      return nil
    }

    let bufferedWireBytesPerSubscriber = maximumWireBytes * subscriberBufferCapacity
    guard
      bufferedWireBytesPerSubscriber
        <= Self.hardMaximumBufferedWireBytesAcrossSubscribers / maximumSubscribersPerRun,
      maximumRetainedWireBytesPerRun
        <= Self.hardMaximumRetainedWireBytesAcrossRuns / maximumRememberedRuns
    else {
      return nil
    }

    self.init(
      validatedMaximumWireBytes: maximumWireBytes,
      validatedMaximumRetainedRecordsPerRun: maximumRetainedRecordsPerRun,
      validatedMaximumRetainedWireBytesPerRun: maximumRetainedWireBytesPerRun,
      validatedSubscriberBufferCapacity: subscriberBufferCapacity,
      validatedMaximumSubscribersPerRun: maximumSubscribersPerRun,
      validatedMaximumSessions: maximumSessions,
      validatedMaximumRememberedRuns: maximumRememberedRuns
    )
  }

  private init(
    validatedMaximumWireBytes: Int,
    validatedMaximumRetainedRecordsPerRun: Int,
    validatedMaximumRetainedWireBytesPerRun: Int,
    validatedSubscriberBufferCapacity: Int,
    validatedMaximumSubscribersPerRun: Int,
    validatedMaximumSessions: Int,
    validatedMaximumRememberedRuns: Int
  ) {
    maximumWireBytes = validatedMaximumWireBytes
    maximumRetainedRecordsPerRun = validatedMaximumRetainedRecordsPerRun
    maximumRetainedWireBytesPerRun = validatedMaximumRetainedWireBytesPerRun
    subscriberBufferCapacity = validatedSubscriberBufferCapacity
    maximumSubscribersPerRun = validatedMaximumSubscribersPerRun
    maximumSessions = validatedMaximumSessions
    maximumRememberedRuns = validatedMaximumRememberedRuns
  }
}
