import HexCore

@testable import HexProviders

actor TestCodexAppServerTransport: CodexAppServerTransport {
  private var outcomes: [TestCodexAppServerTransportOutcome]
  private var recordedRequests: [CodexAppServerRequest] = []
  private var generationRetirementCount = 0

  init(outcomes: [TestCodexAppServerTransportOutcome]) {
    self.outcomes = outcomes
  }

  func send(_ request: CodexAppServerRequest) async throws -> JSONValue {
    recordedRequests.append(request)
    guard !outcomes.isEmpty else {
      throw TestCodexAppServerTransportError.unexpectedRequest("transport-secret")
    }

    switch outcomes.removeFirst() {
    case .value(let value):
      return value
    case .failure:
      throw TestCodexAppServerTransportError.failed("transport-secret")
    case .cancellation:
      throw CancellationError()
    }
  }

  func requests() -> [CodexAppServerRequest] {
    recordedRequests
  }

  func retireAccountLoginFlowGeneration() {
    generationRetirementCount += 1
  }

  func retirementCount() -> Int {
    generationRetirementCount
  }
}
