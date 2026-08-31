struct SQLiteRunIntegrityState {
  let nextSequence: Int64
  let terminalSequence: Int64?
  let recordCount: Int64
  let minimumSequence: Int64?
  let maximumSequence: Int64?
  let runStartedKindCount: Int64
  let terminalKindCount: Int64
}
