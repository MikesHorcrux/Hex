import HexCore

struct SQLiteValidatedRunSnapshot {
  let pageRecords: [AgentEventRecord]
  let recordCount: Int64
  let minimumSequence: Int64?
  let maximumSequence: Int64?
  let runStartedEventCount: Int64
  let terminalEventCount: Int64
  let firstRecordStartsRun: Bool
  let lastRecordTerminatesRun: Bool
}
