import Foundation

/// Durable-journal limits and deterministic dependencies.
public struct SQLiteAgentEventJournalConfiguration: Sendable {
  static let hardMaximumBusyTimeoutMilliseconds = 60_000
  static let hardMaximumReadLimit = 10_000
  static let hardMaximumPayloadBytes = 16 * 1_024 * 1_024
  static let hardMaximumReadBytes = 64 * 1_024 * 1_024
  static let hardMaximumTextBytes = 1 * 1_024 * 1_024
  static let hardMaximumRecoveryRunCount = 10_000
  static let hardMaximumRecoveryRecordCount = 100_000
  static let hardMaximumRecoveryBytes = 128 * 1_024 * 1_024

  /// A database file inside a dedicated journal directory. Opening the journal requires that
  /// directory to be owned by the current user and secures it to mode 0700.
  public let databaseURL: URL
  public let busyTimeoutMilliseconds: Int
  public let maximumReadLimit: Int
  public let maximumPayloadBytes: Int
  public let maximumReadBytes: Int
  public let maximumTextBytes: Int
  public let maximumRecoveryRunCount: Int
  public let maximumRecoveryRecordCount: Int
  public let maximumRecoveryBytes: Int
  public let clock: @Sendable () -> Date
  public let uuidGenerator: @Sendable () -> UUID

  public init(
    databaseURL: URL,
    busyTimeoutMilliseconds: Int = 5_000,
    maximumReadLimit: Int = 1_000,
    maximumPayloadBytes: Int = 8 * 1_024 * 1_024,
    maximumReadBytes: Int = 32 * 1_024 * 1_024,
    maximumTextBytes: Int = 64 * 1_024,
    maximumRecoveryRunCount: Int = 1_000,
    maximumRecoveryRecordCount: Int = 50_000,
    maximumRecoveryBytes: Int = 64 * 1_024 * 1_024,
    clock: @escaping @Sendable () -> Date = { Date() },
    uuidGenerator: @escaping @Sendable () -> UUID = { UUID() }
  ) {
    self.databaseURL = databaseURL
    self.busyTimeoutMilliseconds = busyTimeoutMilliseconds
    self.maximumReadLimit = maximumReadLimit
    self.maximumPayloadBytes = maximumPayloadBytes
    self.maximumReadBytes = maximumReadBytes
    self.maximumTextBytes = maximumTextBytes
    self.maximumRecoveryRunCount = maximumRecoveryRunCount
    self.maximumRecoveryRecordCount = maximumRecoveryRecordCount
    self.maximumRecoveryBytes = maximumRecoveryBytes
    self.clock = clock
    self.uuidGenerator = uuidGenerator
  }

  func validated() throws -> Self {
    guard databaseURL.isFileURL, !databaseURL.path.isEmpty, !databaseURL.lastPathComponent.isEmpty
    else {
      throw SQLiteAgentEventJournalError.invalidConfiguration(
        "databaseURL must be a nonempty file URL."
      )
    }
    guard
      busyTimeoutMilliseconds > 0,
      busyTimeoutMilliseconds <= Self.hardMaximumBusyTimeoutMilliseconds
    else {
      throw SQLiteAgentEventJournalError.invalidConfiguration(
        "busyTimeoutMilliseconds must be between 1 and \(Self.hardMaximumBusyTimeoutMilliseconds)."
      )
    }
    guard maximumReadLimit > 0, maximumReadLimit <= Self.hardMaximumReadLimit else {
      throw SQLiteAgentEventJournalError.invalidConfiguration(
        "maximumReadLimit must be between 1 and \(Self.hardMaximumReadLimit)."
      )
    }
    guard maximumPayloadBytes > 0, maximumPayloadBytes <= Self.hardMaximumPayloadBytes else {
      throw SQLiteAgentEventJournalError.invalidConfiguration(
        "maximumPayloadBytes must be between 1 and \(Self.hardMaximumPayloadBytes)."
      )
    }
    guard maximumReadBytes > 0, maximumReadBytes <= Self.hardMaximumReadBytes else {
      throw SQLiteAgentEventJournalError.invalidConfiguration(
        "maximumReadBytes must be between 1 and \(Self.hardMaximumReadBytes)."
      )
    }
    guard maximumTextBytes >= 36, maximumTextBytes <= Self.hardMaximumTextBytes else {
      throw SQLiteAgentEventJournalError.invalidConfiguration(
        "maximumTextBytes must be between 36 and \(Self.hardMaximumTextBytes)."
      )
    }
    guard
      maximumRecoveryRunCount > 0,
      maximumRecoveryRunCount <= Self.hardMaximumRecoveryRunCount
    else {
      throw SQLiteAgentEventJournalError.invalidConfiguration(
        "maximumRecoveryRunCount must be between 1 and \(Self.hardMaximumRecoveryRunCount)."
      )
    }
    guard
      maximumRecoveryRecordCount > 0,
      maximumRecoveryRecordCount <= Self.hardMaximumRecoveryRecordCount
    else {
      throw SQLiteAgentEventJournalError.invalidConfiguration(
        "maximumRecoveryRecordCount must be between 1 and \(Self.hardMaximumRecoveryRecordCount)."
      )
    }
    guard
      maximumRecoveryBytes > 0,
      maximumRecoveryBytes <= Self.hardMaximumRecoveryBytes
    else {
      throw SQLiteAgentEventJournalError.invalidConfiguration(
        "maximumRecoveryBytes must be between 1 and \(Self.hardMaximumRecoveryBytes)."
      )
    }
    return self
  }
}
