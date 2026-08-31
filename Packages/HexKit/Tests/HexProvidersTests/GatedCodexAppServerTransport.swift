import HexCore

@testable import HexProviders

actor GatedCodexAppServerTransport: CodexAppServerTransport {
  private var requests: [CodexAppServerRequest] = []
  private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  private var responseWaiters: [CheckedContinuation<JSONValue, any Error>] = []
  private var shouldBlockGenerationRetirement = false
  private var generationRetirementCount = 0
  private var generationRetirementStarted = false
  private var generationRetirementStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var generationRetirementReleaseWaiters: [CheckedContinuation<Void, Never>] = []

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

  func requestCount() -> Int {
    requests.count
  }

  func succeed(with value: JSONValue) {
    guard !responseWaiters.isEmpty else { return }
    responseWaiters.removeFirst().resume(returning: value)
  }

  func retireAccountLoginFlowGeneration() async {
    generationRetirementCount += 1
    generationRetirementStarted = true
    let startWaiters = generationRetirementStartWaiters
    generationRetirementStartWaiters = []
    for waiter in startWaiters {
      waiter.resume()
    }
    if shouldBlockGenerationRetirement {
      await withCheckedContinuation { continuation in
        generationRetirementReleaseWaiters.append(continuation)
      }
    }
    let pendingResponses = responseWaiters
    responseWaiters = []
    for response in pendingResponses {
      response.resume(throwing: TestCodexAppServerTransportError.failed("transport-secret"))
    }
  }

  func blockGenerationRetirement() {
    shouldBlockGenerationRetirement = true
  }

  func waitUntilGenerationRetirementStarts() async {
    guard !generationRetirementStarted else { return }
    await withCheckedContinuation { continuation in
      generationRetirementStartWaiters.append(continuation)
    }
  }

  func releaseGenerationRetirement() {
    shouldBlockGenerationRetirement = false
    let waiters = generationRetirementReleaseWaiters
    generationRetirementReleaseWaiters = []
    for waiter in waiters {
      waiter.resume()
    }
  }

  func retirementCount() -> Int {
    generationRetirementCount
  }
}
