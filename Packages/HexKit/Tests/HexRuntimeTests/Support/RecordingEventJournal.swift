import Foundation
import HexCore

actor RecordingEventJournal: AgentEventJournal {
  private var storedRecords: [AgentEventRecord] = []
  private let failOn: EventJournalTarget?
  private let blockOn: EventJournalTarget?
  private let cancelAfterPersistOn: EventJournalTarget?
  private var didFail = false
  private var didBlock = false
  private var didCancel = false
  private var blocked = false
  private var blockedContinuation: CheckedContinuation<Void, Never>?
  private var appendCount = 0

  init(
    failOn: EventJournalTarget? = nil,
    blockOn: EventJournalTarget? = nil,
    cancelAfterPersistOn: EventJournalTarget? = nil
  ) {
    self.failOn = failOn
    self.blockOn = blockOn
    self.cancelAfterPersistOn = cancelAfterPersistOn
  }

  func append(
    _ event: AgentEvent,
    to runID: AgentRunID
  ) async throws -> AgentEventRecord {
    appendCount += 1

    if let blockOn, !didBlock, matches(blockOn, event: event, appendNumber: appendCount) {
      didBlock = true
      blocked = true
      await withCheckedContinuation { continuation in
        blockedContinuation = continuation
      }
      blocked = false
    }

    if let failOn, !didFail, matches(failOn, event: event, appendNumber: appendCount) {
      didFail = true
      throw RecordingEventJournalError.append
    }

    let record = AgentEventRecord(
      id: AgentEventID(),
      runID: runID,
      sequence: UInt64(storedRecords.filter { $0.runID == runID }.count + 1),
      timestamp: Date(timeIntervalSince1970: TimeInterval(storedRecords.count + 1)),
      event: event
    )
    storedRecords.append(record)
    if let cancelAfterPersistOn,
      !didCancel,
      matches(cancelAfterPersistOn, event: event, appendNumber: appendCount)
    {
      didCancel = true
      withUnsafeCurrentTask { task in
        task?.cancel()
      }
    }
    return record
  }

  func records(
    for runID: AgentRunID,
    after sequence: UInt64?,
    limit: Int
  ) async throws -> [AgentEventRecord] {
    guard limit > 0 else {
      return []
    }
    let minimum = sequence ?? 0
    return Array(
      storedRecords
        .filter { $0.runID == runID && $0.sequence > minimum }
        .prefix(limit)
    )
  }

  func events() -> [AgentEvent] {
    storedRecords.map(\.event)
  }

  func isBlocked() -> Bool {
    blocked
  }

  func releaseBlockedAppend() {
    let continuation = blockedContinuation
    blockedContinuation = nil
    continuation?.resume()
  }

  private func matches(
    _ target: EventJournalTarget,
    event: AgentEvent,
    appendNumber: Int
  ) -> Bool {
    switch target {
    case .runStarted:
      if case .runStarted = event { return true }
    case .runCompleted:
      if case .runCompleted = event { return true }
    case .toolStarted:
      if case .toolStarted = event { return true }
    case .toolFinished:
      if case .toolFinished = event { return true }
    case .inferenceEvent:
      if case .inferenceEvent = event { return true }
    case .authorizationRequested:
      if case .authorizationRequested = event { return true }
    case .runCancelled:
      if case .runCancelled = event { return true }
    case .runFailed:
      if case .runFailed = event { return true }
    case .appendNumber(let expected):
      return appendNumber == expected
    }
    return false
  }
}
