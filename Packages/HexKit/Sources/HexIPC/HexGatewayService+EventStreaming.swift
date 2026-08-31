import Foundation
import HexCore

extension HexGatewayService {
  /// Atomically enqueues retained records and installs the live subscriber without an actor
  /// suspension point, preventing an event from falling between replay and live delivery.
  public func eventRecords(
    after untrustedCursor: GatewayEventCursor,
    sessionID untrustedSessionID: GatewaySessionID
  ) throws -> AsyncThrowingStream<AgentEventRecord, any Error> {
    let sessionID = try codec.roundTrip(untrustedSessionID)
    let cursor = try codec.roundTrip(untrustedCursor)
    try requireSession(sessionID)

    guard var state = runs[cursor.runID] else {
      throw GatewayFailure(
        code: .runNotFound,
        message: "The requested run is unavailable in this gateway instance."
      )
    }

    guard cursor.sequence <= state.latestSequence else {
      throw GatewayFailure(
        code: .invalidCursor,
        message: "The event cursor is ahead of the gateway high-water mark."
      )
    }

    if let firstRetainedSequence = state.retainedRecords.first?.sequence,
      cursor.sequence < firstRetainedSequence - 1
    {
      throw GatewayFailure(
        code: .replayUnavailable,
        message: "The requested event cursor predates the retained replay window."
      )
    }

    let pair = AsyncThrowingStream<AgentEventRecord, any Error>.makeStream(
      bufferingPolicy: .bufferingOldest(configuration.subscriberBufferCapacity)
    )
    let stream = pair.stream
    let continuation = pair.continuation

    for record in state.retainedRecords where record.sequence > cursor.sequence {
      guard enqueue(record, into: continuation) else {
        continuation.finish(
          throwing: GatewayFailure(
            code: .consumerTooSlow,
            message: "The event consumer could not accept the retained replay window.",
            isRetryable: true
          )
        )
        return stream
      }
    }

    if let completionFailure = state.completionFailure {
      continuation.finish(throwing: completionFailure)
      return stream
    }

    if state.phase == .terminal {
      continuation.finish()
      return stream
    }

    guard state.subscribers.count < configuration.maximumSubscribersPerRun else {
      continuation.finish(
        throwing: GatewayFailure(
          code: .capacityExceeded,
          message: "The run has reached its configured live-subscriber limit.",
          isRetryable: true
        )
      )
      return stream
    }

    let subscriberID = UUID()
    state.subscribers[subscriberID] = GatewaySubscriber(
      sessionID: sessionID,
      continuation: continuation
    )
    runs[cursor.runID] = state

    continuation.onTermination = { @Sendable [weak self] _ in
      Task {
        await self?.removeSubscriber(runID: cursor.runID, subscriberID: subscriberID)
      }
    }

    return stream
  }

  func accept(
    _ untrustedRecord: AgentEventRecord,
    for runID: AgentRunID,
    invocationID: GatewayRunInvocationID
  ) throws {
    guard var state = runs[runID] else {
      throw GatewayFailure(
        code: .runNotFound,
        message: "The run driver emitted an event for an unknown run."
      )
    }

    guard state.invocationID == invocationID else {
      throw GatewayFailure(
        code: .runDriverFailed,
        message: "The run driver callback belongs to a stale run invocation."
      )
    }

    guard state.phase != .terminal else {
      throw GatewayFailure(
        code: .eventAfterTerminal,
        message: "The run driver emitted a record after a terminal outcome was committed."
      )
    }

    let record: AgentEventRecord
    let wireByteCount: Int
    do {
      let encodedRecord = try codec.encode(untrustedRecord)
      record = try codec.decode(AgentEventRecord.self, from: encodedRecord)
      wireByteCount = encodedRecord.count
    } catch let failure as GatewayFailure {
      failRun(runID, invocationID: invocationID, with: failure)
      throw failure
    } catch {
      let failure = GatewayFailure(
        code: .malformedPayload,
        message: "The run driver emitted a record that could not cross the gateway boundary."
      )
      failRun(runID, invocationID: invocationID, with: failure)
      throw failure
    }

    guard record.runID == runID else {
      let failure = GatewayFailure(
        code: .wrongRun,
        message: "The run driver emitted a record for the wrong run."
      )
      failRun(runID, invocationID: invocationID, with: failure)
      throw failure
    }

    guard record.schemaVersion == 1 else {
      let failure = GatewayFailure(
        code: .unsupportedEventSchema,
        message: "The event record schema version is unsupported."
      )
      failRun(runID, invocationID: invocationID, with: failure)
      throw failure
    }

    let nextSequence = state.latestSequence.addingReportingOverflow(1)
    guard !nextSequence.overflow, record.sequence == nextSequence.partialValue else {
      let failure = GatewayFailure(
        code: .invalidEventSequence,
        message: "The run driver emitted a duplicate, missing, or overflowing sequence."
      )
      failRun(runID, invocationID: invocationID, with: failure)
      throw failure
    }

    if record.sequence == 1 {
      guard case .runStarted = record.event else {
        let failure = GatewayFailure(
          code: .invalidEventSequence,
          message: "The first run event must be runStarted."
        )
        failRun(runID, invocationID: invocationID, with: failure)
        throw failure
      }
    } else if case .runStarted = record.event {
      let failure = GatewayFailure(
        code: .invalidEventSequence,
        message: "A run may emit runStarted only once."
      )
      failRun(runID, invocationID: invocationID, with: failure)
      throw failure
    }

    let retainedWireByteTotal = state.retainedWireBytes.addingReportingOverflow(wireByteCount)
    guard !retainedWireByteTotal.overflow else {
      let failure = GatewayFailure(
        code: .capacityExceeded,
        message: "The retained replay byte accounting overflowed."
      )
      failRun(runID, invocationID: invocationID, with: failure)
      throw failure
    }

    state.latestSequence = record.sequence
    if isTerminal(record.event) {
      state.phase = .terminal
      state.terminalSequence = record.sequence
    } else if state.phase != .cancelling {
      state.phase = .running
    }

    state.retainedRecords.append(record)
    state.retainedRecordWireByteCounts.append(wireByteCount)
    state.retainedWireBytes = retainedWireByteTotal.partialValue
    while state.retainedRecords.count > configuration.maximumRetainedRecordsPerRun
      || state.retainedWireBytes > configuration.maximumRetainedWireBytesPerRun
    {
      guard
        !state.retainedRecords.isEmpty,
        !state.retainedRecordWireByteCounts.isEmpty
      else {
        let failure = GatewayFailure(
          code: .runDriverFailed,
          message: "The retained replay accounting became inconsistent."
        )
        failRun(runID, invocationID: invocationID, with: failure)
        throw failure
      }
      state.retainedRecords.removeFirst()
      let removedWireByteCount = state.retainedRecordWireByteCounts.removeFirst()
      state.retainedWireBytes -= removedWireByteCount
    }

    let slowConsumerFailure = GatewayFailure(
      code: .consumerTooSlow,
      message: "The event consumer fell behind the bounded gateway buffer.",
      isRetryable: true
    )
    var subscribersToRemove: [UUID] = []
    for (subscriberID, subscriber) in state.subscribers {
      guard enqueue(record, into: subscriber.continuation) else {
        subscriber.continuation.finish(throwing: slowConsumerFailure)
        subscribersToRemove.append(subscriberID)
        continue
      }
    }
    for subscriberID in subscribersToRemove {
      state.subscribers.removeValue(forKey: subscriberID)
    }

    // The durable terminal record is the public stream completion commit point. The driver task may
    // still be unwinding (or may be defective and never return), but consumers must not wait on its
    // lifecycle after they have received the terminal fact. State keeps the terminal sequence so any
    // later driver output still fails internally without changing replay, and releasing run ownership
    // at this same commit lets another run start even if the completed driver unwinds slowly.
    if state.phase == .terminal {
      for subscriber in state.subscribers.values {
        subscriber.continuation.finish()
      }
      state.subscribers.removeAll()
    }

    runs[runID] = state
    if state.terminalSequence != nil {
      finishRunOwnership(runID, invocationID: invocationID)
    }
  }

  private func enqueue(
    _ record: AgentEventRecord,
    into continuation: AsyncThrowingStream<AgentEventRecord, any Error>.Continuation
  ) -> Bool {
    switch continuation.yield(record) {
    case .enqueued:
      return true
    case .dropped, .terminated:
      return false
    @unknown default:
      return false
    }
  }

  private func isTerminal(_ event: AgentEvent) -> Bool {
    switch event {
    case .runCompleted, .runCancelled, .runFailed:
      true
    default:
      false
    }
  }

  private func removeSubscriber(runID: AgentRunID, subscriberID: UUID) {
    guard var state = runs[runID] else {
      return
    }
    state.subscribers.removeValue(forKey: subscriberID)
    runs[runID] = state
  }
}
