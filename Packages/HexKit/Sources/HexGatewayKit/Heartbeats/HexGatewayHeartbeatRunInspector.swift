import HexCore
import HexIPC

/// Uses the same authenticated, read-only recovery path as the app's saved-run reader.
public struct HexGatewayHeartbeatRunInspector: HexHeartbeatRunInspecting {
  private let client: HexGatewayClient

  public init(client: HexGatewayClient) {
    self.client = client
  }

  public func inspect(_ lease: HexHeartbeatLease) async throws -> HexHeartbeatRunInspection {
    guard let runID = lease.runID else { return .unknown }
    let response = try await client.recoverRun(GatewayRunRecoveryRequest(runID: runID))
    switch response.disposition {
    case .resident(let snapshot, _, let journal):
      if let journal, let result = try terminal(journal, lease: lease) { return result }
      return snapshot.phase == .terminal ? .unknown : .running
    case .journaled(let journal):
      return try terminal(journal, lease: lease) ?? .unknown
    case .unknown:
      return .unknown
    }
  }

  private func terminal(_ snapshot: GatewayJournalRunSnapshot, lease: HexHeartbeatLease) throws
    -> HexHeartbeatRunInspection?
  {
    guard let record = snapshot.terminalRecord else { return nil }
    let kind: HexHeartbeatOutcomeKind
    let failure: HexHeartbeatFailure?
    switch record.event {
    case .runCompleted:
      kind = .succeeded
      failure = nil
    case .runCancelled:
      kind = .cancelled
      failure = HexHeartbeatFailure(
        code: .cancelled, message: "The scheduled run was cancelled.", retryable: false)
    case .runFailed(let value):
      kind = .failed
      failure = HexHeartbeatFailure(
        code: .runnerFailed, message: Self.failurePreview(value.message),
        retryable: value.isRetryable)
    default:
      throw GatewayFailure(
        code: .malformedPayload, message: "The saved run has invalid terminal evidence.")
    }
    return .terminal(
      outcome: HexHeartbeatOutcome(
        occurrence: lease.occurrence, kind: kind, completedAt: record.timestamp, failure: failure),
      journal: HexHeartbeatRunJournalIdentity(
        runID: snapshot.runID, firstEventID: snapshot.firstEventID,
        terminalSequence: snapshot.latestSequence))
  }

  /// Receipt metadata shares the wire/store's 4 KiB bound. This preview never changes the original
  /// terminal event, which remains available through the anchored saved-run reader.
  private static func failurePreview(_ message: String) -> String {
    guard !message.isEmpty else {
      return "The scheduled run failed. Open saved run activity for details."
    }
    let maximumBytes = GatewayHeartbeatOutcome.maximumFailureMessageBytes
    guard message.utf8.count > maximumBytes else { return message }
    let marker = "\n[Preview truncated. Open saved run activity for the full failure.]"
    let prefixBudget = maximumBytes - marker.utf8.count
    var preview = ""
    var prefixBytes = 0
    // Bound at Unicode-scalar boundaries: a raw UTF-8 prefix could split a scalar and introduce
    // replacement characters, altering the evidence or exceeding the remaining byte budget.
    for scalar in message.unicodeScalars {
      let bytes = String(scalar).utf8.count
      guard prefixBytes + bytes <= prefixBudget else { break }
      preview.unicodeScalars.append(scalar)
      prefixBytes += bytes
    }
    return preview + marker
  }
}
