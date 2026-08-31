import HexCore

@testable import HexProviders

actor TestCodexAppServerTransport: CodexAppServerTransport {
  nonisolated let accountLoginFlowGeneration: CodexAccountLoginFlowGenerationController
  private var outcomes: [TestCodexAppServerTransportOutcome]
  private var recordedRequests: [CodexAppServerRequest] = []
  private var generationRetirementCount = 0
  private var generationRetirementStarted = false

  init(outcomes: [TestCodexAppServerTransportOutcome]) {
    accountLoginFlowGeneration = CodexAccountLoginFlowGenerationController()
    self.outcomes = outcomes
  }

  init?(
    outcomes: [TestCodexAppServerTransportOutcome],
    loginFlowHistoryCapacity: Int
  ) {
    guard (1...64).contains(loginFlowHistoryCapacity) else {
      return nil
    }
    accountLoginFlowGeneration = CodexAccountLoginFlowGenerationController(
      validatedCapacity: loginFlowHistoryCapacity
    )
    self.outcomes = outcomes
  }

  func send(_ request: CodexAppServerRequest) async throws -> JSONValue {
    try await accountLoginFlowGeneration.ensureUsable()
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

  func retireAccountLoginFlowGeneration() async {
    guard !generationRetirementStarted else { return }
    generationRetirementStarted = true
    await accountLoginFlowGeneration.retireGeneration()
    generationRetirementCount += 1
  }

  func retirementCount() -> Int {
    generationRetirementCount
  }
}
