import HexCore
import HexIPC

actor ABAGatewayRunDriver: HexGatewayRunDriver {
  private var nextInvocation = 1
  private var continuations: [Int: AsyncThrowingStream<AgentEventRecord, any Error>.Continuation] =
    [:]
  private var processedRecordCounts: [Int: Int] = [:]
  private var emissionFailureCounts: [Int: Int] = [:]
  private var stoppedInvocations: Set<Int> = []

  func run(
    _ request: GatewayStartRunRequest,
    emit: @escaping @Sendable (AgentEventRecord) async throws -> Void
  ) async throws {
    let invocation = nextInvocation
    nextInvocation += 1
    let pair = AsyncThrowingStream<AgentEventRecord, any Error>.makeStream()
    continuations[invocation] = pair.continuation

    for try await record in pair.stream {
      do {
        try await emit(record)
      } catch {
        emissionFailureCounts[invocation, default: 0] += 1
      }
      processedRecordCounts[invocation, default: 0] += 1
    }

    continuations.removeValue(forKey: invocation)
    stoppedInvocations.insert(invocation)
  }

  func waitUntilStarted(_ invocation: Int) async {
    while continuations[invocation] == nil {
      await Task.yield()
    }
  }

  func yieldAndWait(_ record: AgentEventRecord, from invocation: Int) async {
    let expectedCount = processedRecordCounts[invocation, default: 0] + 1
    _ = continuations[invocation]?.yield(record)
    while processedRecordCounts[invocation, default: 0] < expectedCount,
      !stoppedInvocations.contains(invocation)
    {
      await Task.yield()
    }
  }

  func finish(_ invocation: Int) {
    continuations[invocation]?.finish()
  }

  func waitUntilStopped(_ invocation: Int) async {
    while !stoppedInvocations.contains(invocation) {
      await Task.yield()
    }
  }

  func emissionFailureCount(for invocation: Int) -> Int {
    emissionFailureCounts[invocation, default: 0]
  }
}
