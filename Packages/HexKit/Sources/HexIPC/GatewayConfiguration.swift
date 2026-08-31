public struct GatewayConfiguration: Equatable, Sendable {
  public static var standard: GatewayConfiguration {
    GatewayConfiguration(
      validatedMaximumWireBytes: 1_048_576,
      validatedMaximumRetainedRecordsPerRun: 4_096,
      validatedSubscriberBufferCapacity: 4_096,
      validatedMaximumSubscribersPerRun: 8,
      validatedMaximumSessions: 16,
      validatedMaximumRememberedRuns: 128
    )
  }

  public let maximumWireBytes: Int
  public let maximumRetainedRecordsPerRun: Int
  public let subscriberBufferCapacity: Int
  public let maximumSubscribersPerRun: Int
  public let maximumSessions: Int
  public let maximumRememberedRuns: Int

  public init?(
    maximumWireBytes: Int,
    maximumRetainedRecordsPerRun: Int,
    subscriberBufferCapacity: Int,
    maximumSubscribersPerRun: Int = 8,
    maximumSessions: Int = 16,
    maximumRememberedRuns: Int = 128
  ) {
    guard
      maximumWireBytes > 0,
      maximumRetainedRecordsPerRun > 0,
      subscriberBufferCapacity >= maximumRetainedRecordsPerRun,
      maximumSubscribersPerRun > 0,
      maximumSessions > 0,
      maximumRememberedRuns > 0
    else {
      return nil
    }

    self.init(
      validatedMaximumWireBytes: maximumWireBytes,
      validatedMaximumRetainedRecordsPerRun: maximumRetainedRecordsPerRun,
      validatedSubscriberBufferCapacity: subscriberBufferCapacity,
      validatedMaximumSubscribersPerRun: maximumSubscribersPerRun,
      validatedMaximumSessions: maximumSessions,
      validatedMaximumRememberedRuns: maximumRememberedRuns
    )
  }

  private init(
    validatedMaximumWireBytes: Int,
    validatedMaximumRetainedRecordsPerRun: Int,
    validatedSubscriberBufferCapacity: Int,
    validatedMaximumSubscribersPerRun: Int,
    validatedMaximumSessions: Int,
    validatedMaximumRememberedRuns: Int
  ) {
    maximumWireBytes = validatedMaximumWireBytes
    maximumRetainedRecordsPerRun = validatedMaximumRetainedRecordsPerRun
    subscriberBufferCapacity = validatedSubscriberBufferCapacity
    maximumSubscribersPerRun = validatedMaximumSubscribersPerRun
    maximumSessions = validatedMaximumSessions
    maximumRememberedRuns = validatedMaximumRememberedRuns
  }
}
