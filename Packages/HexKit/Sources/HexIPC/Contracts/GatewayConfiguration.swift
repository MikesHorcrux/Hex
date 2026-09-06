public struct GatewayConfiguration: Equatable, Sendable {
  /// The standard wire envelope reserves one MiB beyond HexRuntime's standard 7,340,032-byte
  /// journal-event budget for `GatewayEventEnvelope` metadata and JSON framing. HexIPC intentionally
  /// does not depend on HexRuntime, so integration must keep these two documented budgets aligned.
  ///
  /// Replay retains at most eight records and 32 MiB per run. Each forwarding queue separately
  /// admits at most 256 records AND 64 MiB of actual encoded payload. Tiny text fragments therefore
  /// tolerate ordinary UI scheduling pauses without permitting 256 maximum-sized envelopes.
  /// A reconnect older than the replay window requires durable journal recovery.
  public static var standard: GatewayConfiguration {
    GatewayConfiguration(
      validatedMaximumWireBytes: 8_388_608,
      validatedMaximumRetainedRecordsPerRun: 8,
      validatedMaximumRetainedWireBytesPerRun: 33_554_432,
      validatedSubscriberBufferCapacity: 256,
      validatedMaximumBufferedWireBytesPerSubscriber: 67_108_864,
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
  public let maximumBufferedWireBytesPerSubscriber: Int
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
    let bytes = maximumWireBytes.multipliedReportingOverflow(by: subscriberBufferCapacity)
    guard !bytes.overflow else { return nil }
    self.init(
      maximumWireBytes: maximumWireBytes,
      maximumRetainedRecordsPerRun: maximumRetainedRecordsPerRun,
      maximumRetainedWireBytesPerRun: maximumRetainedWireBytesPerRun,
      subscriberBufferCapacity: subscriberBufferCapacity,
      maximumBufferedWireBytesPerSubscriber: bytes.partialValue,
      maximumSubscribersPerRun: maximumSubscribersPerRun,
      maximumSessions: maximumSessions,
      maximumRememberedRuns: maximumRememberedRuns)
  }

  public init?(
    maximumWireBytes: Int,
    maximumRetainedRecordsPerRun: Int,
    maximumRetainedWireBytesPerRun: Int = 33_554_432,
    subscriberBufferCapacity: Int,
    maximumBufferedWireBytesPerSubscriber: Int,
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
      maximumRememberedRuns <= Self.hardMaximumRememberedRuns
    else {
      return nil
    }

    let bufferedWireBytesPerSubscriber = maximumBufferedWireBytesPerSubscriber
    guard
      bufferedWireBytesPerSubscriber >= maximumWireBytes,
      bufferedWireBytesPerSubscriber <= Self.hardMaximumBufferedWireBytesPerSubscriber,
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
      validatedMaximumBufferedWireBytesPerSubscriber: bufferedWireBytesPerSubscriber,
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
    validatedMaximumBufferedWireBytesPerSubscriber: Int,
    validatedMaximumSubscribersPerRun: Int,
    validatedMaximumSessions: Int,
    validatedMaximumRememberedRuns: Int
  ) {
    maximumWireBytes = validatedMaximumWireBytes
    maximumRetainedRecordsPerRun = validatedMaximumRetainedRecordsPerRun
    maximumRetainedWireBytesPerRun = validatedMaximumRetainedWireBytesPerRun
    subscriberBufferCapacity = validatedSubscriberBufferCapacity
    maximumBufferedWireBytesPerSubscriber = validatedMaximumBufferedWireBytesPerSubscriber
    maximumSubscribersPerRun = validatedMaximumSubscribersPerRun
    maximumSessions = validatedMaximumSessions
    maximumRememberedRuns = validatedMaximumRememberedRuns
  }
}
