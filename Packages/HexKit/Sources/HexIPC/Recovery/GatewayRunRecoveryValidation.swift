import Foundation
import HexCore

enum GatewayRunRecoveryValidation {
  static let maximumPageRecords = 64

  static func identity(_ value: UUID) throws {
    guard value != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) else {
      throw GatewayFailure(
        code: .malformedPayload, message: "Recovery contains an invalid identity.")
    }
  }

  static func request(_ request: GatewayRunHistoryRequest) throws {
    try identity(request.runID.rawValue)
    try identity(request.firstEventID.rawValue)
    guard request.throughSequence > 0, request.throughSequence <= UInt64(Int64.max),
      request.afterSequence <= request.throughSequence
    else {
      throw GatewayFailure(code: .invalidCursor, message: "The durable recovery cursor is invalid.")
    }
    guard (1...maximumPageRecords).contains(request.limit) else {
      throw GatewayFailure(code: .malformedPayload, message: "The recovery page limit is invalid.")
    }
  }

  static func snapshot(_ snapshot: GatewayJournalRunSnapshot, runID: AgentRunID) throws {
    guard snapshot.runID == runID else { throw wrongRun() }
    try identity(snapshot.firstEventID.rawValue)
    guard snapshot.latestSequence > 0, snapshot.latestSequence <= UInt64(Int64.max) else {
      throw GatewayFailure(
        code: .invalidCursor, message: "The durable recovery high-water is invalid.")
    }
    if let terminal = snapshot.terminalRecord {
      try record(terminal, runID: runID, sequence: snapshot.latestSequence)
      guard isTerminal(terminal.event) else { throw malformedHistory() }
    }
  }

  static func response(
    _ response: GatewayRunRecoveryResponse, runID: AgentRunID, instanceID: GatewayInstanceID
  ) throws {
    guard response.gatewayInstanceID == instanceID else {
      throw GatewayFailure(
        code: .staleSession, message: "The recovery response belongs to another gateway instance.")
    }
    guard response.runID == runID else { throw wrongRun() }
    switch response.disposition {
    case .unknown: break
    case .journaled(let journal): try snapshot(journal, runID: runID)
    case .resident(let resident, let floor, let journal):
      guard resident.runID == runID else { throw wrongRun() }
      try identity(resident.invocationID.rawValue)
      guard resident.latestSequence <= UInt64(Int64.max), floor <= resident.latestSequence else {
        throw GatewayFailure(
          code: .invalidCursor, message: "The resident replay bounds are invalid.")
      }
      if let journal { try snapshot(journal, runID: runID) }
    }
  }

  static func page(
    _ page: GatewayRunHistoryPage, request: GatewayRunHistoryRequest, instanceID: GatewayInstanceID
  ) throws {
    guard page.gatewayInstanceID == instanceID else {
      throw GatewayFailure(
        code: .staleSession, message: "The history page belongs to another gateway instance.")
    }
    guard page.runID == request.runID else { throw wrongRun() }
    guard page.firstEventID == request.firstEventID, page.afterSequence == request.afterSequence,
      page.throughSequence == request.throughSequence
    else {
      throw GatewayFailure(
        code: .invalidCursor, message: "The history page does not match its fixed snapshot.")
    }
    guard page.records.count <= request.limit, page.records.count <= maximumPageRecords else {
      throw malformedHistory()
    }
    var seen = Set<AgentEventID>()
    for (index, item) in page.records.enumerated() {
      let expected = request.afterSequence + UInt64(index) + 1
      guard expected <= request.throughSequence, seen.insert(item.id).inserted else {
        throw malformedHistory()
      }
      try record(item, runID: request.runID, sequence: expected)
      if expected == 1 {
        guard item.id == request.firstEventID, item.event == .runStarted else {
          throw malformedHistory()
        }
      } else if item.event == .runStarted {
        throw malformedHistory()
      }
      if isTerminal(item.event), expected != request.throughSequence { throw malformedHistory() }
    }
    let last = page.records.last?.sequence ?? request.afterSequence
    guard last == request.throughSequence || !page.records.isEmpty,
      page.nextAfterSequence == (last < request.throughSequence ? last : nil)
    else {
      throw malformedHistory()
    }
  }

  static func record(_ record: AgentEventRecord, runID: AgentRunID, sequence: UInt64) throws {
    guard record.runID == runID else { throw wrongRun() }
    try identity(record.id.rawValue)
    guard record.schemaVersion == 1 else {
      throw GatewayFailure(
        code: .unsupportedEventSchema, message: "The history record schema is unsupported.")
    }
    guard record.sequence == sequence else { throw malformedHistory() }
    if case .contextCompacted(let compaction) = record.event {
      guard compaction.ownerRunID == runID else { throw wrongRun() }
      _ = try compaction.validated()
    }
  }

  static func isTerminal(_ event: AgentEvent) -> Bool {
    switch event {
    case .runCompleted, .runCancelled, .runFailed: true
    default: false
    }
  }
  static func wrongRun() -> GatewayFailure {
    GatewayFailure(code: .wrongRun, message: "Recovery returned evidence for another run.")
  }
  static func malformedHistory() -> GatewayFailure {
    GatewayFailure(
      code: .invalidEventSequence,
      message: "The durable history page is incomplete or contradictory.")
  }
}
