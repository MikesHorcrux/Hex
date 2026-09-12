enum JSONHexInferenceBackendSettingsLockAttempt<Result: Sendable>: Sendable {
  case acquired(Result)
  case busy
}
