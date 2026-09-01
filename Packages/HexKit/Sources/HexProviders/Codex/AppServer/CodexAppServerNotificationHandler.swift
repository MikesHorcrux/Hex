/// Serial notification boundary for a Codex app-server connection.
///
/// Implementations must be cancellation-cooperative and return promptly. The connection
/// intentionally backpressures its reader while a notification is being handled.
public protocol CodexAppServerNotificationHandler: Sendable {
  func handle(_ notification: CodexAppServerNotification) async throws
}
