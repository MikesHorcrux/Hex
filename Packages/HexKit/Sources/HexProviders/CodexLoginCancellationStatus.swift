/// Result of cancelling a Codex-managed login flow.
public enum CodexLoginCancellationStatus: Equatable, Sendable {
  case cancelled
  case notFound
}
