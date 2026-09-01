import HexCore
import HexIPC

actor ControllableGatewayRunDriver: HexGatewayRunDriver {
  private var continuations:
    [AgentRunID: AsyncThrowingStream<AgentEventRecord, any Error>.Continuation] = [:]
  private var requests: [AgentRunID: GatewayStartRunRequest] = [:]
  private var invocationCounts: [AgentRunID: Int] = [:]
  private var cancellationRecords: [AgentRunID: AgentEventRecord] = [:]
  private var processedSequences: [AgentRunID: UInt64] = [:]

  func run(
    _ request: GatewayStartRunRequest,
    emit: @escaping @Sendable (AgentEventRecord) async throws -> Void
  ) async throws {
    let pair = AsyncThrowingStream<AgentEventRecord, any Error>.makeStream()
    continuations[request.runID] = pair.continuation
    requests[request.runID] = request
    invocationCounts[request.runID, default: 0] += 1

    do {
      for try await record in pair.stream {
        try Task.checkCancellation()
        try await emit(record)
        processedSequences[request.runID] = record.sequence
      }
      try Task.checkCancellation()
    } catch is CancellationError {
      if let cancellationRecord = cancellationRecords[request.runID] {
        try await emit(cancellationRecord)
      }
      continuations.removeValue(forKey: request.runID)
      throw CancellationError()
    } catch {
      continuations.removeValue(forKey: request.runID)
      throw error
    }

    continuations.removeValue(forKey: request.runID)
  }

  func waitUntilStarted(_ runID: AgentRunID) async {
    while invocationCounts[runID, default: 0] == 0 {
      await Task.yield()
    }
  }

  func waitUntilStopped(_ runID: AgentRunID) async {
    while continuations[runID] != nil {
      await Task.yield()
    }
  }

  func yield(_ record: AgentEventRecord) {
    _ = continuations[record.runID]?.yield(record)
  }

  func yield(_ record: AgentEventRecord, to runID: AgentRunID) {
    _ = continuations[runID]?.yield(record)
  }

  func yieldAndWait(_ record: AgentEventRecord, to runID: AgentRunID? = nil) async {
    let destinationRunID = runID ?? record.runID
    _ = continuations[destinationRunID]?.yield(record)
    while processedSequences[destinationRunID, default: 0] < record.sequence,
      continuations[destinationRunID] != nil
    {
      await Task.yield()
    }
  }

  func finish(_ runID: AgentRunID) {
    continuations[runID]?.finish()
  }

  func fail(_ runID: AgentRunID) {
    continuations[runID]?.finish(
      throwing: GatewayFailure(
        code: .runDriverFailed,
        message: "Scripted run driver failure."
      )
    )
  }

  func setCancellationRecord(_ record: AgentEventRecord) {
    cancellationRecords[record.runID] = record
  }

  func invocationCount(for runID: AgentRunID) -> Int {
    invocationCounts[runID, default: 0]
  }

  func isRunning(_ runID: AgentRunID) -> Bool {
    continuations[runID] != nil
  }

  func request(for runID: AgentRunID) -> GatewayStartRunRequest? {
    requests[runID]
  }
}
