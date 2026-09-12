import Foundation
import HexCore

struct AgentEventCodec {
  static let recordSchemaVersion: UInt16 = 1
  static let checkpointSchemaVersion: UInt16 = 1

  static func encode(event: AgentEvent) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(event)
  }

  static func decodeEvent(from data: Data, schemaVersion: Int64) throws -> AgentEvent {
    guard schemaVersion == Int64(recordSchemaVersion) else {
      throw SQLiteAgentEventJournalError.unsupportedRecordSchemaVersion(Int(schemaVersion))
    }
    do {
      return try JSONDecoder().decode(AgentEvent.self, from: data)
    } catch let error as CancellationError {
      throw error
    } catch let error as SQLiteAgentEventJournalError {
      throw error
    } catch {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "The event payload is not valid schema-version-one JSON."
      )
    }
  }

  static func encode(snapshot: JSONValue) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(snapshot)
  }

  static func decodeSnapshot(from data: Data, schemaVersion: Int64) throws -> JSONValue {
    guard schemaVersion == Int64(checkpointSchemaVersion) else {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "Checkpoint schema version \(schemaVersion) is unsupported."
      )
    }
    do {
      return try JSONDecoder().decode(JSONValue.self, from: data)
    } catch let error as CancellationError {
      throw error
    } catch {
      throw SQLiteAgentEventJournalError.corruptRecord(
        "The checkpoint snapshot is not valid schema-version-one JSON."
      )
    }
  }

  static func microseconds(for date: Date) throws -> Int64 {
    let scaled = date.timeIntervalSince1970 * 1_000_000
    guard scaled.isFinite, let value = Int64(exactly: scaled.rounded(.towardZero)) else {
      throw SQLiteAgentEventJournalError.invalidConfiguration(
        "The clock produced a date outside the supported microsecond range."
      )
    }
    return value
  }

  static func date(for microseconds: Int64) -> Date {
    Date(timeIntervalSince1970: Double(microseconds) / 1_000_000)
  }
}
