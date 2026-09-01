import HexCore
import HexIPC

actor InvalidEmissionHangingGatewayRunDriver: HexGatewayRunDriver {
  private var invocationCount = 0
  private var didCatchInvalidEmission = false
  private var didStartReplacement = false
  private var invalidReleaseContinuation: CheckedContinuation<Void, Never>?
  private var replacementReleaseContinuation: CheckedContinuation<Void, Never>?

  func run(
    _ request: GatewayStartRunRequest,
    emit: @escaping @Sendable (AgentEventRecord) async throws -> Void
  ) async throws {
    invocationCount += 1
    if invocationCount == 1 {
      do {
        try await emit(
          GatewayTestValues.record(runID: request.runID, sequence: 2, event: .runCompleted)
        )
      } catch {
        didCatchInvalidEmission = true
      }
      await withCheckedContinuation { continuation in
        invalidReleaseContinuation = continuation
      }
      return
    }

    try await emit(
      GatewayTestValues.record(runID: request.runID, sequence: 1, event: .runStarted)
    )
    didStartReplacement = true
    await withCheckedContinuation { continuation in
      replacementReleaseContinuation = continuation
    }
    try await emit(
      GatewayTestValues.record(runID: request.runID, sequence: 2, event: .runCompleted)
    )
  }

  func waitUntilInvalidEmissionWasCaught() async {
    while !didCatchInvalidEmission {
      await Task.yield()
    }
  }

  func waitUntilReplacementStarted() async {
    while !didStartReplacement {
      await Task.yield()
    }
  }

  func releaseInvalidInvocation() {
    let continuation = invalidReleaseContinuation
    invalidReleaseContinuation = nil
    continuation?.resume()
  }

  func releaseReplacement() {
    let continuation = replacementReleaseContinuation
    replacementReleaseContinuation = nil
    continuation?.resume()
  }
}
