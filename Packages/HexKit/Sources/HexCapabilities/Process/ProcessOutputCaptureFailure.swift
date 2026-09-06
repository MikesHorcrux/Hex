/// Capture failures do not replace an already-known process exit code.
public enum ProcessOutputCaptureFailure: String, Equatable, Sendable {
  case quotaExceeded = "quota_exceeded"
  case storageFailure = "storage_failure"
}
