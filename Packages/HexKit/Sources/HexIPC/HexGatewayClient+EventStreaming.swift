import Foundation
import HexCore

extension HexGatewayClient {
  public func eventRecords(
    for runID: AgentRunID,
    invocationID: GatewayRunInvocationID
  ) async throws -> AsyncThrowingStream<AgentEventRecord, any Error> {
    try Task.checkCancellation()
    try validateEventRoute(runID: runID, invocationID: invocationID)
    let connection = try requireConnectedGeneration()
    let cursor = acknowledgedCursor(for: runID, invocationID: invocationID)
    let firstSequence = cursor.sequence.addingReportingOverflow(1)
    guard !firstSequence.overflow else {
      throw GatewayFailure(
        code: .invalidCursor,
        message: "The gateway event cursor cannot advance beyond its sequence."
      )
    }
    let upstream: AsyncThrowingStream<AgentEventRecord, any Error>
    do {
      upstream = try await transport.eventRecords(
        after: cursor,
        lease: connection.lease
      )
    } catch {
      try Task.checkCancellation()
      try requireCurrentConnectedGeneration(connection.generationID)
      throw error
    }

    try Task.checkCancellation()
    try requireCurrentConnectedGeneration(connection.generationID)
    let streamID = UUID()
    let pair = AsyncThrowingStream<AgentEventRecord, any Error>.makeStream(
      bufferingPolicy: .bufferingOldest(configuration.subscriberBufferCapacity)
    )
    let task = Task { [weak self] in
      guard let self else {
        pair.continuation.finish()
        return
      }
      do {
        var expectedSequence: UInt64? = firstSequence.partialValue
        for try await record in upstream {
          guard let requiredSequence = expectedSequence else {
            throw invalidEventSequenceFailure()
          }
          try self.validateEventRecord(
            record,
            runID: runID,
            requiredSequence: requiredSequence
          )
          let followingSequence = record.sequence.addingReportingOverflow(1)
          expectedSequence = followingSequence.overflow ? nil : followingSequence.partialValue
          guard
            await self.enqueue(
              record,
              streamID: streamID,
              generationID: connection.generationID
            )
          else {
            return
          }
        }
        await self.finishEventStream(streamID, generationID: connection.generationID)
      } catch is CancellationError {
        await self.finishEventStream(
          streamID,
          generationID: connection.generationID,
          error: CancellationError()
        )
      } catch {
        await self.finishEventStream(
          streamID,
          generationID: connection.generationID,
          error: error
        )
      }
    }
    pair.continuation.onTermination = { @Sendable _ in
      task.cancel()
      Task {
        await self.removeEventStream(streamID, generationID: connection.generationID)
      }
    }
    eventStreams[streamID] = GatewayClientEventStreamState(
      generationID: connection.generationID,
      continuation: pair.continuation,
      task: task
    )
    return pair.stream
  }

  nonisolated func validateEventRoute(
    runID: AgentRunID,
    invocationID: GatewayRunInvocationID
  ) throws {
    let zeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    guard runID.rawValue != zeroUUID, invocationID.rawValue != zeroUUID else {
      throw GatewayFailure(
        code: .malformedPayload,
        message: "The gateway event route contains an invalid identity."
      )
    }
  }

  nonisolated func validateEventRecord(
    _ record: AgentEventRecord,
    runID: AgentRunID,
    requiredSequence: UInt64
  ) throws {
    guard record.runID == runID else {
      throw GatewayFailure(
        code: .wrongRun,
        message: "The gateway returned an event record for a different run."
      )
    }
    guard record.schemaVersion == 1 else {
      throw GatewayFailure(
        code: .unsupportedEventSchema,
        message: "The gateway returned an unsupported event record schema."
      )
    }
    let zeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    guard record.id.rawValue != zeroUUID else {
      throw GatewayFailure(
        code: .malformedPayload,
        message: "The gateway returned an event record with an invalid identity."
      )
    }
    guard record.sequence == requiredSequence else {
      throw invalidEventSequenceFailure()
    }
  }

  nonisolated func invalidEventSequenceFailure() -> GatewayFailure {
    GatewayFailure(
      code: .invalidEventSequence,
      message: "The gateway returned a noncontiguous event sequence."
    )
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
