@testable import HexProviders

actor RecordingCodexAppServerNotificationHandler: CodexAppServerNotificationHandler {
  private var values: [CodexAppServerNotification] = []
  private var shouldFail = false

  func handle(_ notification: CodexAppServerNotification) async throws {
    if shouldFail {
      throw TestCodexAppServerChannelError.failed("handler-secret")
    }
    values.append(notification)
  }

  func notifications() -> [CodexAppServerNotification] {
    values
  }

  func setShouldFail(_ enabled: Bool) {
    shouldFail = enabled
  }
}
