import Foundation

@testable import HexProviders

actor GatedCodexAppServerNotificationHandler: CodexAppServerNotificationHandler {
  private var didStart = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func handle(_ notification: CodexAppServerNotification) async throws {
    didStart = true
    let waiters = startWaiters
    startWaiters = []
    for waiter in waiters {
      waiter.resume()
    }
    await withCheckedContinuation { continuation in
      releaseWaiters.append(continuation)
    }
  }

  func waitUntilStarted() async {
    guard !didStart else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func release() {
    let waiters = releaseWaiters
    releaseWaiters = []
    for waiter in waiters {
      waiter.resume()
    }
  }
}
