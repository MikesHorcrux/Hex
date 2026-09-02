/// Provides a redacted account/availability projection for Codex compatibility mode.
public protocol CodexCompatibilityAccountStatusProviding: Sendable {
  func status() async -> CodexCompatibilityAccountStatus
}
