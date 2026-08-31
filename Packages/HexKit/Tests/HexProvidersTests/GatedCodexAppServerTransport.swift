import HexCore

@testable import HexProviders

actor GatedCodexAppServerTransport: CodexAppServerTransport {
  private var requests: [CodexAppServerRequest] = []
  private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  private var responseWaiters: [CheckedContinuation<JSONValue, any Error>] = []

  func send(_ request: CodexAppServerRequest) async throws -> JSONValue {
    requests.append(request)
    let readyWaiters = requestWaiters.filter { $0.0 <= requests.count }
    requestWaiters.removeAll { $0.0 <= requests.count }
    for waiter in readyWaiters {
      waiter.1.resume()
    }
    return try await withCheckedThrowingContinuation { continuation in
      responseWaiters.append(continuation)
    }
  }

  func waitForRequest(count: Int = 1) async {
    guard requests.count < count else { return }
    await withCheckedContinuation { continuation in
      requestWaiters.append((count, continuation))
    }
  }

  func succeed(with value: JSONValue) {
    guard !responseWaiters.isEmpty else { return }
    responseWaiters.removeFirst().resume(returning: value)
  }
}
