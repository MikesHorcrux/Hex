import Foundation
import HexCore

extension HexGatewayClient {
  /// Attaches only to a queried, existing invocation after the caller has applied and durably
  /// saved history through this sequence. No start is performed and a failed attachment leaves
  /// existing acknowledgement state unchanged. Concurrent streams cannot have their cursor reset.
  public func eventRecords(
    for runID: AgentRunID, invocationID: GatewayRunInvocationID, afterSequence: UInt64
  ) async throws -> AsyncThrowingStream<GatewayEventEnvelope, any Error> {
    try Task.checkCancellation()
    try validateEventRoute(runID: runID, invocationID: invocationID)
    let connection = try requireConnectedGeneration()
    guard eventCheckpointRestorations[runID] == nil,
      !eventStreams.values.contains(where: { $0.runID == runID }),
      !eventStreamReservations.values.contains(where: { $0.runID == runID })
    else {
      throw GatewayFailure(
        code: .capacityExceeded, message: "A run stream is already attached or attaching.")
    }
    let token = UUID()
    eventCheckpointRestorations[runID] = token
    defer {
      if eventCheckpointRestorations[runID] == token {
        eventCheckpointRestorations.removeValue(forKey: runID)
      }
    }
    let recovered = try await recoverRun(GatewayRunRecoveryRequest(runID: runID))
    try Task.checkCancellation()
    try requireCurrentConnectedGeneration(connection.generationID)
    guard case .resident(let snapshot, let floor, let journal) = recovered.disposition,
      snapshot.invocationID == invocationID
    else {
      throw GatewayFailure(
        code: .staleRunInvocation,
        message: "The requested live invocation is no longer available. No run was started.")
    }
    guard afterSequence >= floor, afterSequence <= snapshot.latestSequence else {
      throw GatewayFailure(
        code: .invalidCursor,
        message: "The saved history cursor is outside the current live replay window.")
    }
    let cancellationState = GatewayClientEventStreamCancellationState()
    return try await withTaskCancellationHandler {
      try await acquireEventRecords(
        for: runID, invocationID: invocationID, cancellationState: cancellationState,
        checkpoint: (afterSequence, journal?.terminalRecord?.sequence == afterSequence, token))
    } onCancel: {
      cancellationState.cancel()
    }
  }

  public func eventRecords(
    for runID: AgentRunID,
    invocationID: GatewayRunInvocationID
  ) async throws -> AsyncThrowingStream<GatewayEventEnvelope, any Error> {
    let cancellationState = GatewayClientEventStreamCancellationState()
    return try await withTaskCancellationHandler {
      try await acquireEventRecords(
        for: runID,
        invocationID: invocationID,
        cancellationState: cancellationState
      )
    } onCancel: {
      cancellationState.cancel()
    }
  }

  private func acquireEventRecords(
    for runID: AgentRunID,
    invocationID: GatewayRunInvocationID,
    cancellationState: GatewayClientEventStreamCancellationState,
    checkpoint: (sequence: UInt64, terminal: Bool, token: UUID)? = nil
  ) async throws -> AsyncThrowingStream<GatewayEventEnvelope, any Error> {
    try Task.checkCancellation()
    try validateEventRoute(runID: runID, invocationID: invocationID)
    guard eventCheckpointRestorations[runID] == checkpoint?.token else {
      throw GatewayFailure(
        code: .capacityExceeded, message: "A durable checkpoint attachment is already in progress.")
    }
    let connection = try requireConnectedGeneration()
    let cursor =
      checkpoint.map {
        GatewayEventCursor(runID: runID, invocationID: invocationID, sequence: $0.sequence)
      }
      ?? acknowledgedCursor(for: runID, invocationID: invocationID)
    let acknowledgementKey = GatewayRunAcknowledgementKey(
      runID: runID,
      invocationID: invocationID
    )
    let hasAcknowledgedTerminal =
      checkpoint?.terminal ?? terminalAcknowledgements.contains(acknowledgementKey)
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
      generationID: connection.generationID,
      lease: connection.lease,
      cancellationState: cancellationState
    )
    defer {
      releaseEventStreamReservation(
        reservationID,
        generationID: connection.generationID,
        lease: connection.lease
      )
    }

    let upstream: AsyncThrowingStream<GatewayEventEnvelope, any Error>
    do {
      try await acquirePhysicalEventStreamSlot(
        reservationID: reservationID,
        generationID: connection.generationID,
        lease: connection.lease,
        cancellationState: cancellationState
      )
      try Task.checkCancellation()
      upstream = try await transport.eventRecords(
        after: cursor,
        lease: connection.lease
      )
    } catch {
      releasePhysicalEventStreamSlot(reservationID)
      try Task.checkCancellation()
      try requireCurrentConnectedGeneration(connection.generationID)
      invalidateConnectionIfUnavailable(error, generationID: connection.generationID)
      throw error
    }

    do {
      try Task.checkCancellation()
      try requireCurrentConnectedGeneration(connection.generationID)
    } catch {
      await terminateUnpublishedEventStream(upstream)
      releasePhysicalEventStreamSlot(reservationID)
      throw error
    }
    releasePhysicalEventStreamSlot(reservationID)
    if let checkpoint {
      removeAcknowledgements(for: runID)
      storeAcknowledgement(checkpoint.sequence, for: acknowledgementKey)
      if checkpoint.terminal { terminalAcknowledgements.insert(acknowledgementKey) }
    }
    let streamID = UUID()
    let pair = GatewayBufferedStream<GatewayEventEnvelope>.makeStream(
      bufferCapacity: configuration.subscriberBufferCapacity,
      maximumBufferedBytes: configuration.maximumBufferedWireBytesPerSubscriber)
    let continuation = pair.continuation
    let task = Task { [weak self] in
      guard let self else {
        continuation.finish()
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
            try await self.enqueue(
              envelope,
              streamID: streamID,
              generationID: connection.generationID
            )
          else {
            return
          }
          // Applying and acknowledging an event also visits this actor. Do not monopolize it
          // while draining a provider burst that is already buffered by the transport.
          await Task.yield()
        }
        try Task.checkCancellation()
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
    if case .contextCompacted(let compaction) = record.event, compaction.ownerRunID != runID {
      throw GatewayFailure(
        code: .wrongRun,
        message: "The gateway returned context compaction for a different run.")
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
  ) throws -> Bool {
    guard let state = eventStreams[streamID],
      state.generationID == generationID,
      connectedGenerationID == generationID,
      connectionGenerationID == generationID
    else {
      return false
    }
    let wireBytes = try GatewayWireCodec(configuration: configuration).encode(envelope).count
    switch state.continuation.yield(envelope, wireBytes: wireBytes) {
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
      invalidateConnectionIfUnavailable(error, generationID: generationID)
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

  func terminateEventStreamsForConnectionChange(failure: GatewayFailure? = nil) {
    let states = Array(eventStreams.values)
    eventStreams.removeAll()
    let failure = failure ?? supersededOperationFailure()
    for state in states {
      state.continuation.finish(throwing: failure)
      state.task.cancel()
    }
  }

  func reserveEventStream(
    runID: AgentRunID,
    invocationID: GatewayRunInvocationID,
    generationID: GatewayClientConnectionGenerationID,
    lease: GatewayTransportConnectionLease,
    cancellationState: GatewayClientEventStreamCancellationState
  ) throws -> UUID {
    removeCancelledEventStreamReservations()
    try Task.checkCancellation()
    guard !cancellationState.isCancelled else {
      throw CancellationError()
    }
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
      generationID: generationID,
      lease: lease,
      cancellationState: cancellationState
    )
    return reservationID
  }

  func acquirePhysicalEventStreamSlot(
    reservationID: UUID,
    generationID: GatewayClientConnectionGenerationID,
    lease: GatewayTransportConnectionLease,
    cancellationState: GatewayClientEventStreamCancellationState
  ) async throws {
    try Task.checkCancellation()
    guard !cancellationState.isCancelled else {
      throw CancellationError()
    }
    try requireCurrentConnectedGeneration(generationID)
    guard
      let reservation = eventStreamReservations[reservationID],
      reservation.generationID == generationID,
      reservation.lease == lease,
      reservation.cancellationState === cancellationState
    else {
      throw supersededOperationFailure()
    }

    if physicalEventStreamAcquisitionIDs.count < maximumPhysicalEventStreamAcquisitions {
      physicalEventStreamAcquisitionIDs.insert(reservationID)
      return
    }

    removeCancelledEventStreamReservations()
    guard eventStreamAcquisitionWaiters.count < maximumPhysicalEventStreamAcquisitions else {
      throw GatewayFailure(
        code: .capacityExceeded,
        message: "The client has reached its configured pending stream-acquisition limit.",
        isRetryable: true
      )
    }

    let signal = AsyncThrowingStream<Void, any Error>.makeStream(
      bufferingPolicy: .bufferingNewest(1)
    )
    cancellationState.installCancellationHandler {
      signal.continuation.finish(throwing: CancellationError())
    }
    defer {
      cancellationState.removeCancellationHandler()
    }
    guard !cancellationState.isCancelled else {
      throw CancellationError()
    }

    eventStreamAcquisitionWaiters.append(
      GatewayClientEventStreamAcquisitionWaiter(
        reservationID: reservationID,
        generationID: generationID,
        lease: lease,
        cancellationState: cancellationState,
        continuation: signal.continuation
      )
    )

    do {
      var iterator = signal.stream.makeAsyncIterator()
      guard try await iterator.next() != nil else {
        throw supersededOperationFailure()
      }
    } catch {
      removeEventStreamAcquisitionWaiter(reservationID)
      releasePhysicalEventStreamSlot(reservationID)
      try Task.checkCancellation()
      guard !cancellationState.isCancelled else {
        throw CancellationError()
      }
      try requireCurrentConnectedGeneration(generationID)
      throw error
    }

    removeEventStreamAcquisitionWaiter(reservationID)
    do {
      try Task.checkCancellation()
      guard !cancellationState.isCancelled else {
        throw CancellationError()
      }
      try requireCurrentConnectedGeneration(generationID)
      guard physicalEventStreamAcquisitionIDs.contains(reservationID) else {
        throw supersededOperationFailure()
      }
    } catch {
      releasePhysicalEventStreamSlot(reservationID)
      throw error
    }
  }

  func releaseEventStreamReservation(
    _ reservationID: UUID,
    generationID: GatewayClientConnectionGenerationID,
    lease: GatewayTransportConnectionLease
  ) {
    guard
      let reservation = eventStreamReservations[reservationID],
      reservation.generationID == generationID,
      reservation.lease == lease
    else {
      return
    }
    eventStreamReservations.removeValue(forKey: reservationID)
  }

  func releasePhysicalEventStreamSlot(_ reservationID: UUID) {
    guard physicalEventStreamAcquisitionIDs.remove(reservationID) != nil else {
      return
    }
    resumeEventStreamAcquisitionWaiters()
  }

  func terminateEventStreamAcquisitionWaitersForConnectionChange(failure: GatewayFailure? = nil) {
    let waiters = eventStreamAcquisitionWaiters
    eventStreamAcquisitionWaiters.removeAll(keepingCapacity: true)
    eventStreamReservations.removeAll(keepingCapacity: true)
    let failure = failure ?? supersededOperationFailure()
    for waiter in waiters {
      waiter.continuation.finish(throwing: failure)
    }
  }

  private var maximumPhysicalEventStreamAcquisitions: Int {
    configuration.maximumSubscribersPerRun * configuration.maximumRememberedRuns
  }

  private func removeCancelledEventStreamReservations() {
    let cancelledReservationIDs = Set(
      eventStreamReservations.compactMap { reservationID, reservation in
        reservation.cancellationState.isCancelled ? reservationID : nil
      }
    )
    guard !cancelledReservationIDs.isEmpty else {
      return
    }

    for reservationID in cancelledReservationIDs {
      eventStreamReservations.removeValue(forKey: reservationID)
    }

    var retainedWaiters: [GatewayClientEventStreamAcquisitionWaiter] = []
    retainedWaiters.reserveCapacity(eventStreamAcquisitionWaiters.count)
    for waiter in eventStreamAcquisitionWaiters {
      if cancelledReservationIDs.contains(waiter.reservationID) {
        waiter.continuation.finish(throwing: CancellationError())
      } else {
        retainedWaiters.append(waiter)
      }
    }
    eventStreamAcquisitionWaiters = retainedWaiters
    resumeEventStreamAcquisitionWaiters()
  }

  private func removeEventStreamAcquisitionWaiter(_ reservationID: UUID) {
    eventStreamAcquisitionWaiters.removeAll { waiter in
      waiter.reservationID == reservationID
    }
  }

  private func resumeEventStreamAcquisitionWaiters() {
    while physicalEventStreamAcquisitionIDs.count < maximumPhysicalEventStreamAcquisitions,
      !eventStreamAcquisitionWaiters.isEmpty
    {
      let waiter = eventStreamAcquisitionWaiters.removeFirst()
      guard
        let reservation = eventStreamReservations[waiter.reservationID],
        reservation.generationID == waiter.generationID,
        reservation.lease == waiter.lease,
        reservation.cancellationState === waiter.cancellationState,
        connectionGenerationID == waiter.generationID,
        connectedGenerationID == waiter.generationID,
        connectedLease == waiter.lease
      else {
        waiter.continuation.finish(throwing: supersededOperationFailure())
        continue
      }
      guard !waiter.cancellationState.isCancelled else {
        eventStreamReservations.removeValue(forKey: waiter.reservationID)
        waiter.continuation.finish(throwing: CancellationError())
        continue
      }

      physicalEventStreamAcquisitionIDs.insert(waiter.reservationID)
      switch waiter.continuation.yield(()) {
      case .enqueued:
        waiter.continuation.finish()
      case .dropped, .terminated:
        physicalEventStreamAcquisitionIDs.remove(waiter.reservationID)
        eventStreamReservations.removeValue(forKey: waiter.reservationID)
      @unknown default:
        physicalEventStreamAcquisitionIDs.remove(waiter.reservationID)
        eventStreamReservations.removeValue(forKey: waiter.reservationID)
        waiter.continuation.finish(throwing: supersededOperationFailure())
      }
    }
  }

  nonisolated func terminateUnpublishedEventStream(
    _ stream: AsyncThrowingStream<GatewayEventEnvelope, any Error>
  ) async {
    let task = Task {
      do {
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()
      } catch {
        // Cancellation is the cleanup signal; upstream failures are intentionally not published.
      }
    }
    task.cancel()
    _ = await task.result
  }
}
