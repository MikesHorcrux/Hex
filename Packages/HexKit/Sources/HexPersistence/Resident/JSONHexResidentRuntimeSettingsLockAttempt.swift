enum JSONHexResidentRuntimeSettingsLockAttempt<Result: Sendable>: Sendable {
  case acquired(Result)
  case busy
}
