import Foundation
import HexCore

public enum SQLiteAgentEventJournalError: Error, Equatable, LocalizedError, Sendable {
  case invalidConfiguration(String)
  case ownershipUnavailable
  case closed
  case database(code: Int32, message: String)
  case futureSchemaVersion(found: Int, supported: Int)
  case corruptSchema(String)
  case corruptRecord(String)
  case unsupportedRecordSchemaVersion(Int)
  case duplicateRun(AgentRunID)
  case runNotFound(AgentRunID)
  case runAlreadyTerminal(AgentRunID)
  case sequenceOverflow(AgentRunID)
  case invalidReadLimit(requested: Int, maximum: Int)
  case payloadTooLarge(actual: Int, maximum: Int)
  case textTooLarge(actual: Int, maximum: Int)
  case readByteLimitExceeded(actual: Int, maximum: Int)
  case recoveryRunLimitExceeded(maximum: Int)
  case recoveryRecordLimitExceeded(maximum: Int)
  case recoveryByteLimitExceeded(actual: Int, maximum: Int)
  case integrityRunLimitExceeded(maximum: Int)
  case integrityRecordLimitExceeded(maximum: Int)
  case integrityByteLimitExceeded(actual: Int, maximum: Int)
  case checkpointSequenceMissing(runID: AgentRunID, sequence: UInt64)
  case checkpointConflict(runID: AgentRunID, sequence: UInt64)

  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration(let reason):
      "Invalid journal configuration: \(reason)"
    case .ownershipUnavailable:
      "Another process already owns this journal."
    case .closed:
      "The journal is closed."
    case .database(let code, let message):
      "SQLite error \(code): \(message)"
    case .futureSchemaVersion(let found, let supported):
      "Journal schema version \(found) is newer than supported version \(supported)."
    case .corruptSchema(let reason):
      "Journal schema is corrupt: \(reason)"
    case .corruptRecord(let reason):
      "Journal record is corrupt: \(reason)"
    case .unsupportedRecordSchemaVersion(let version):
      "Journal record schema version \(version) is unsupported."
    case .duplicateRun(let runID):
      "Run \(runID) has already started."
    case .runNotFound(let runID):
      "Run \(runID) has not started."
    case .runAlreadyTerminal(let runID):
      "Run \(runID) has already reached a terminal event."
    case .sequenceOverflow(let runID):
      "Run \(runID) exhausted the supported sequence range."
    case .invalidReadLimit(let requested, let maximum):
      "Read limit \(requested) must be between 1 and \(maximum)."
    case .payloadTooLarge(let actual, let maximum):
      "Journal payload is \(actual) bytes; the configured maximum is \(maximum)."
    case .textTooLarge(let actual, let maximum):
      "Journal text is \(actual) bytes; the configured maximum is \(maximum)."
    case .readByteLimitExceeded(let actual, let maximum):
      "Journal read decoded \(actual) bytes; the configured maximum is \(maximum)."
    case .recoveryRunLimitExceeded(let maximum):
      "Journal recovery found more than the configured maximum of \(maximum) interrupted runs."
    case .recoveryRecordLimitExceeded(let maximum):
      "Journal recovery found more than the configured maximum of \(maximum) records."
    case .recoveryByteLimitExceeded(let actual, let maximum):
      "Journal recovery decoded \(actual) bytes; the configured maximum is \(maximum)."
    case .integrityRunLimitExceeded(let maximum):
      "Journal integrity validation found more than the configured maximum of \(maximum) runs."
    case .integrityRecordLimitExceeded(let maximum):
      "Journal integrity validation found more than the configured maximum of \(maximum) records."
    case .integrityByteLimitExceeded(let actual, let maximum):
      "Journal integrity validation decoded \(actual) bytes; the configured maximum is \(maximum)."
    case .checkpointSequenceMissing(let runID, let sequence):
      "Checkpoint sequence \(sequence) does not exist for run \(runID)."
    case .checkpointConflict(let runID, let sequence):
      "Checkpoint sequence \(sequence) for run \(runID) is immutable."
    }
  }
}
