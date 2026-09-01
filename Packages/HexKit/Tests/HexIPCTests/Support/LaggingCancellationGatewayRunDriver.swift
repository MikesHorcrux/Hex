import HexCore
import HexIPC

actor LaggingCancellationGatewayRunDriver: HexGatewayRunDriver {
  private var didStart = false
  private var didEmitLateRecord = false
  private var didStop = false
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func run(
    _ request: GatewayStartRunRequest,
    emit: @escaping @Sendable (AgentEventRecord) async throws -> Void
  ) async throws {
    defer { didStop = true }
    try await emit(
      GatewayTestValues.record(runID: request.runID, sequence: 1, event: .runStarted)
    )
    didStart = true

    do {
      try await Task.sleep(for: .seconds(60))
    } catch is CancellationError {
      try await emit(
        GatewayTestValues.record(
          runID: request.runID,
          sequence: 2,
          event: .messageAppended(
            Message(role: .assistant, content: [.text("late while cancelling")])
          )
        )
      )
      didEmitLateRecord = true
      await withCheckedContinuation { continuation in
        releaseContinuation = continuation
      }
      throw CancellationError()
    }
  }

  func waitUntilStarted() async {
    while !didStart {
      await Task.yield()
    }
  }

  func waitUntilLateRecord() async {
    while !didEmitLateRecord {
      await Task.yield()
    }
  }

  func release() {
    let continuation = releaseContinuation
    releaseContinuation = nil
    continuation?.resume()
  }

  func waitUntilStopped() async {
    while !didStop {
      await Task.yield()
    }
  }
}
