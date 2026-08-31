import Foundation
import HexCore

extension HexGatewayClient {
  public func eventRecords(
    for runID: AgentRunID,
    invocationID: GatewayRunInvocationID
  ) async throws -> AsyncThrowingStream<GatewayEventEnvelope, any Error> {
    try Task.checkCancellation()
    try validateEventRoute(runID: runID, invocationID: invocationID)
    let connection = try requireConnectedGeneration()
    let cursor = acknowledgedCursor(for: runID, invocationID: invocationID)
    let acknowledgementKey = GatewayRunAcknowledgementKey(
      runID: runID,
      invocationID: invocationID
    )
    let hasAcknowledgedTerminal = terminalAcknowledgements.contains(acknowledgementKey)
    let firstSequence = cursor.sequence.addingReportingOverflow(1)
    guard !firstSequence.overflow else {
      throw GatewayFailure(
        code: .invalidCursor,
        message: "The gateway event cursor cannot advance beyond its sequence."
      )
    }
    let reservationID = try reserveEventStream(
      runID: runID,
      invocationID: invocationID,
      generationID: connection.generationID
    )
    defer {
      releaseEventStreamReservation(reservationID)
    }

    let upstream: AsyncThrowingStream<GatewayEventEnvelope, any Error>
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

    do {
      try Task.checkCancellation()
      try requireCurrentConnectedGeneration(connection.generationID)
    } catch {
      terminateUnpublishedEventStream(upstream)
      throw error
    }
    let streamID = UUID()
    let pair = AsyncThrowingStream<GatewayEventEnvelope, any Error>.makeStream(
      bufferingPolicy: .bufferingOldest(configuration.subscriberBufferCapacity)
    )
    let task = Task { [weak self] in
      guard let self else {
        pair.continuation.finish()
        return
      }
      do {
        var expectedSequence: UInt64? = firstSequence.partialValue
        var didObserveTerminal = hasAcknowledgedTerminal
        for try await envelope in upstream {
          guard let requiredSequence = expectedSequence else {
            throw invalidEventSequenceFailure()
          }
          let record = try self.validateEventEnvelope(
            envelope,
            runID: runID,
            invocationID: invocationID,
            requiredSequence: requiredSequence
          )
          guard !didObserveTerminal else {
            throw self.eventAfterTerminalFailure()
          }
          didObserveTerminal = self.isTerminal(record.event)
          let followingSequence = record.sequence.addingReportingOverflow(1)
          expectedSequence = followingSequence.overflow ? nil : followingSequence.partialValue
          guard
            await self.enqueue(
              envelope,
              streamID: streamID,
              generationID: connection.generationID
            )
          else {
            return
          }
        }
        guard didObserveTerminal else {
          throw self.missingTerminalEventFailure()
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
      runID: runID,
      invocationID: invocationID,
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

  nonisolated func validateEventEnvelope(
    _ envelope: GatewayEventEnvelope,
    runID: AgentRunID,
    invocationID: GatewayRunInvocationID,
    requiredSequence: UInt64
  ) throws -> AgentEventRecord {
    guard envelope.invocationID == invocationID else {
      throw GatewayFailure(
        code: .staleRunInvocation,
        message: "The gateway returned an event from a different run invocation."
      )
    }
    let record = envelope.record
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
    return record
  }

  nonisolated func invalidEventSequenceFailure() -> GatewayFailure {
    GatewayFailure(
      code: .invalidEventSequence,
      message: "The gateway returned a noncontiguous event sequence."
    )
  }

  nonisolated func eventAfterTerminalFailure() -> GatewayFailure {
    GatewayFailure(
      code: .eventAfterTerminal,
      message: "The gateway returned an event after a terminal outcome."
    )
  }

  nonisolated func missingTerminalEventFailure() -> GatewayFailure {
    GatewayFailure(
      code: .producerEndedWithoutTerminalEvent,
      message: "The gateway event stream ended without a terminal outcome."
    )
  }

  nonisolated func isTerminal(_ event: AgentEvent) -> Bool {
    switch event {
    case .runCompleted, .runCancelled, .runFailed:
      true
    default:
      false
    }
  }

  func enqueue(
    _ envelope: GatewayEventEnvelope,
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
    switch state.continuation.yield(envelope) {
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

  func reserveEventStream(
    runID: AgentRunID,
    invocationID: GatewayRunInvocationID,
    generationID: GatewayClientConnectionGenerationID
  ) throws -> UUID {
    let activeCount = eventStreams.values.count { $0.runID == runID }
    let reservationCount = eventStreamReservations.values.count { $0.runID == runID }
    let totalStreamCount = eventStreams.count + eventStreamReservations.count
    let totalStreamLimit =
      configuration.maximumSubscribersPerRun * configuration.maximumRememberedRuns
    guard
      activeCount + reservationCount < configuration.maximumSubscribersPerRun,
      totalStreamCount < totalStreamLimit
    else {
      throw GatewayFailure(
        code: .capacityExceeded,
        message: "The client has reached its configured live-stream limit for this run.",
        isRetryable: true
      )
    }

    let reservationID = UUID()
    eventStreamReservations[reservationID] = GatewayClientEventStreamReservation(
      runID: runID,
      invocationID: invocationID,
      generationID: generationID
    )
    return reservationID
  }

  func releaseEventStreamReservation(_ reservationID: UUID) {
    eventStreamReservations.removeValue(forKey: reservationID)
  }

  nonisolated func terminateUnpublishedEventStream(
    _ stream: AsyncThrowingStream<GatewayEventEnvelope, any Error>
  ) {
    let task = Task {
      do {
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()
      } catch {
        // Cancellation is the cleanup signal; upstream failures are intentionally not published.
      }
    }
    task.cancel()
  }
}
