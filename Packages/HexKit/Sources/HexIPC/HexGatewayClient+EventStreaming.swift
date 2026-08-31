import Foundation
import HexCore

extension HexGatewayClient {
  public func eventRecords(
    for runID: AgentRunID,
    invocationID: GatewayRunInvocationID
  ) async throws -> AsyncThrowingStream<AgentEventRecord, any Error> {
    try Task.checkCancellation()
    let generationID = try requireConnectedGeneration()
    let upstream: AsyncThrowingStream<AgentEventRecord, any Error>
    do {
      upstream = try await transport.eventRecords(
        after: acknowledgedCursor(for: runID, invocationID: invocationID)
      )
    } catch {
      try Task.checkCancellation()
      try requireCurrentConnectedGeneration(generationID)
      throw error
    }

    try Task.checkCancellation()
    try requireCurrentConnectedGeneration(generationID)
    let streamID = UUID()
    let pair = AsyncThrowingStream<AgentEventRecord, any Error>.makeStream(
      bufferingPolicy: .bufferingOldest(
        GatewayConfiguration.standard.subscriberBufferCapacity
      )
    )
    let task = Task { [weak self] in
      guard let self else {
        pair.continuation.finish()
        return
      }
      do {
        for try await record in upstream {
          guard
            await self.enqueue(
              record,
              streamID: streamID,
              generationID: generationID
            )
          else {
            return
          }
        }
        await self.finishEventStream(streamID, generationID: generationID)
      } catch is CancellationError {
        await self.finishEventStream(
          streamID,
          generationID: generationID,
          error: CancellationError()
        )
      } catch {
        await self.finishEventStream(
          streamID,
          generationID: generationID,
          error: error
        )
      }
    }
    pair.continuation.onTermination = { @Sendable _ in
      task.cancel()
      Task {
        await self.removeEventStream(streamID, generationID: generationID)
      }
    }
    eventStreams[streamID] = GatewayClientEventStreamState(
      generationID: generationID,
      continuation: pair.continuation,
      task: task
    )
    return pair.stream
  }

  func enqueue(
    _ record: AgentEventRecord,
    streamID: UUID,
    generationID: GatewayClientConnectionGenerationID
  ) -> Bool {
    guard let state = eventStreams[streamID],
      state.generationID == generationID,
      connectedGenerationID == generationID,
      connectionGenerationID == generationID
    else {
      return false
    }
    switch state.continuation.yield(record) {
    case .enqueued:
      return true
    case .dropped:
      state.continuation.finish(
        throwing: GatewayFailure(
          code: .consumerTooSlow,
          message: "The gateway client event consumer fell behind its bounded buffer.",
          isRetryable: true
        )
      )
      eventStreams.removeValue(forKey: streamID)
      return false
    case .terminated:
      eventStreams.removeValue(forKey: streamID)
      return false
    @unknown default:
      state.continuation.finish(
        throwing: GatewayFailure(
          code: .consumerTooSlow,
          message: "The gateway client could not enqueue an event record.",
          isRetryable: true
        )
      )
      eventStreams.removeValue(forKey: streamID)
      return false
    }
  }

  func finishEventStream(
    _ streamID: UUID,
    generationID: GatewayClientConnectionGenerationID,
    error: (any Error)? = nil
  ) {
    guard let state = eventStreams[streamID], state.generationID == generationID else {
      return
    }
    eventStreams.removeValue(forKey: streamID)
    if let error {
      state.continuation.finish(throwing: error)
    } else {
      state.continuation.finish()
    }
  }

  func removeEventStream(
    _ streamID: UUID,
    generationID: GatewayClientConnectionGenerationID
  ) {
    guard eventStreams[streamID]?.generationID == generationID else {
      return
    }
    eventStreams.removeValue(forKey: streamID)
  }

  func terminateEventStreamsForConnectionChange() {
    let states = Array(eventStreams.values)
    eventStreams.removeAll()
    let failure = supersededOperationFailure()
    for state in states {
      state.continuation.finish(throwing: failure)
      state.task.cancel()
    }
  }
}
