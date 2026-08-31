@testable import HexProviders

actor AcknowledgingCodexAccountNotificationHandler: CodexAppServerNotificationHandler {
  private let accountClient: CodexAccountClient
  private var handledCount = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(accountClient: CodexAccountClient) {
    self.accountClient = accountClient
  }

  func handle(_ notification: CodexAppServerNotification) async throws {
    try await accountClient.handle(notification)
    handledCount += 1
    let readyWaiters = waiters
    waiters = []
    for waiter in readyWaiters {
      waiter.resume()
    }
  }

  func waitUntilHandled() async {
    guard handledCount == 0 else { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }
}
