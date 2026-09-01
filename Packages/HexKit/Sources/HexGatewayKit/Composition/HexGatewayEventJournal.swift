import Foundation
import HexCore

/// Bridges the runtime's durable journal to the gateway's live event callback. A record is
/// forwarded only after the injected journal has committed it, and each run is checked for the
/// exact sequence shape required by `HexGatewayService`.
actor HexGatewayEventJournal: AgentEventJournal {
  private let base: any AgentEventJournal
  private var emitters: [AgentRunID: @Sendable (AgentEventRecord) async throws -> Void] = [:]
  private var nextSequences: [AgentRunID: UInt64] = [:]
  private var terminalRuns: Set<AgentRunID> = []

  init(base: any AgentEventJournal) {
    self.base = base
  }

  func installEmitter(
    for runID: AgentRunID,
    emit: @escaping @Sendable (AgentEventRecord) async throws -> Void
  ) throws {
    guard emitters[runID] == nil else {
      throw HexGatewayCompositionError.duplicateEmitter
    }
    emitters[runID] = emit
    nextSequences[runID] = 1
    terminalRuns.remove(runID)
  }

  func removeEmitter(for runID: AgentRunID) {
    emitters.removeValue(forKey: runID)
    nextSequences.removeValue(forKey: runID)
    terminalRuns.remove(runID)
  }

  func append(
    _ event: AgentEvent,
    to runID: AgentRunID
  ) async throws -> AgentEventRecord {
    guard let expectedSequence = nextSequences[runID] else {
      throw HexGatewayCompositionError.invalidRecord(
        "The runtime attempted to append without an active gateway run."
      )
    }
    guard !terminalRuns.contains(runID) else {
      throw HexGatewayCompositionError.invalidRecord(
        "The runtime attempted to append after a terminal event."
      )
    }

    let record = try await base.append(event, to: runID)
    try validate(record, expectedRunID: runID, expectedSequence: expectedSequence)

    let (followingSequence, overflowed) = expectedSequence.addingReportingOverflow(1)
    guard !overflowed else {
      throw HexGatewayCompositionError.invalidRecord(
        "The durable event sequence overflowed."
      )
    }
    nextSequences[runID] = followingSequence
    if isTerminal(record.event) {
      terminalRuns.insert(runID)
    }

    if let emit = emitters[runID] {
      do {
        try await emit(record)
      } catch {
        // The durable record remains authoritative. Stop forwarding this run after the transport has
        // rejected one record; later terminal records still commit without a live subscriber.
        emitters.removeValue(forKey: runID)
        throw error
      }
    }
    return record
  }

  func records(
    for runID: AgentRunID,
    after sequence: UInt64?,
    limit: Int
  ) async throws -> [AgentEventRecord] {
    try await base.records(for: runID, after: sequence, limit: limit)
  }

  private func validate(
    _ record: AgentEventRecord,
    expectedRunID: AgentRunID,
    expectedSequence: UInt64
  ) throws {
    guard record.runID == expectedRunID else {
      throw HexGatewayCompositionError.invalidRecord(
        "The durable journal returned a record for the wrong run."
      )
    }
    guard record.schemaVersion == 1 else {
      throw HexGatewayCompositionError.invalidRecord(
        "The durable journal returned an unsupported record schema."
      )
    }
    guard record.sequence == expectedSequence else {
      throw HexGatewayCompositionError.invalidRecord(
        "The durable journal returned a non-increasing event sequence."
      )
    }
    guard record.id.rawValue != Self.zeroUUID else {
      throw HexGatewayCompositionError.invalidRecord(
        "The durable journal returned an event with an invalid identity."
      )
    }
    if expectedSequence == 1 {
      guard case .runStarted = record.event else {
        throw HexGatewayCompositionError.invalidRecord(
          "The first durable event must be runStarted."
        )
      }
    } else if case .runStarted = record.event {
      throw HexGatewayCompositionError.invalidRecord(
        "A run may contain only one runStarted event."
      )
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

  private static let zeroUUID = UUID(
    uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
  )
}
