public struct ProcessExecutionConfiguration: Equatable, Sendable {
  public static var standard: ProcessExecutionConfiguration {
    ProcessExecutionConfiguration(
      validatedMaximumOutputBytes: 512 * 1_024,
      maximumArguments: 256,
      maximumArgumentBytes: 64 * 1_024,
      maximumEnvironmentVariables: 64,
      maximumEnvironmentBytes: 128 * 1_024,
      maximumTimeoutSeconds: 10 * 60,
      pollingIntervalMilliseconds: 10
    )
  }

  /// Maximum combined stdout and stderr bytes retained for one invocation.
  public let maximumOutputBytes: Int
  public let maximumArguments: Int
  public let maximumArgumentBytes: Int
  public let maximumEnvironmentVariables: Int
  public let maximumEnvironmentBytes: Int
  public let maximumTimeoutSeconds: Int
  public let pollingIntervalMilliseconds: Int

  public init(
    maximumOutputBytes: Int = 512 * 1_024,
    maximumArguments: Int = 256,
    maximumArgumentBytes: Int = 64 * 1_024,
    maximumEnvironmentVariables: Int = 64,
    maximumEnvironmentBytes: Int = 128 * 1_024,
    maximumTimeoutSeconds: Int = 10 * 60,
    pollingIntervalMilliseconds: Int = 10
  ) throws {
    guard
      (1...8 * 1_024 * 1_024).contains(maximumOutputBytes),
      (1...4_096).contains(maximumArguments),
      (1...2 * 1_024 * 1_024).contains(maximumArgumentBytes),
      (1...1_024).contains(maximumEnvironmentVariables),
      (1...4 * 1_024 * 1_024).contains(maximumEnvironmentBytes),
      (1...24 * 60 * 60).contains(maximumTimeoutSeconds),
      (1...1_000).contains(pollingIntervalMilliseconds)
    else {
      throw ProcessExecutionError.invalidConfiguration
    }
    self.init(
      validatedMaximumOutputBytes: maximumOutputBytes,
      maximumArguments: maximumArguments,
      maximumArgumentBytes: maximumArgumentBytes,
      maximumEnvironmentVariables: maximumEnvironmentVariables,
      maximumEnvironmentBytes: maximumEnvironmentBytes,
      maximumTimeoutSeconds: maximumTimeoutSeconds,
      pollingIntervalMilliseconds: pollingIntervalMilliseconds
    )
  }

  private init(
    validatedMaximumOutputBytes maximumOutputBytes: Int,
    maximumArguments: Int,
    maximumArgumentBytes: Int,
    maximumEnvironmentVariables: Int,
    maximumEnvironmentBytes: Int,
    maximumTimeoutSeconds: Int,
    pollingIntervalMilliseconds: Int
  ) {
    self.maximumOutputBytes = maximumOutputBytes
    self.maximumArguments = maximumArguments
    self.maximumArgumentBytes = maximumArgumentBytes
    self.maximumEnvironmentVariables = maximumEnvironmentVariables
    self.maximumEnvironmentBytes = maximumEnvironmentBytes
    self.maximumTimeoutSeconds = maximumTimeoutSeconds
    self.pollingIntervalMilliseconds = pollingIntervalMilliseconds
  }
}
