/// Error categories intentionally contain no output bytes, paths, or credentials.
public enum ArtifactStoreError: Error, Equatable, Sendable {
  case quotaExceeded
  case invalidRequest
  case unavailable
  case corrupt
}
