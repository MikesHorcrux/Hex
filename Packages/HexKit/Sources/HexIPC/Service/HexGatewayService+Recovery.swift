import HexCore

extension HexGatewayService {
  /// Queries only. Even an unknown run never invokes the driver or changes run admission state.
  public func recoverRun(_ untrusted: GatewayRunRecoveryRequest, sessionID: GatewaySessionID)
    async throws -> GatewayRunRecoveryResponse
  {
    try Task.checkCancellation()
    let request = try codec.roundTrip(untrusted)
    try requireSession(sessionID)
    try GatewayRunRecoveryValidation.identity(request.runID.rawValue)
    let journal: GatewayJournalRunSnapshot?
    if let historyReader {
      do { journal = try await historyReader.snapshot(for: request.runID) } catch {
        try requireSession(sessionID)
        throw recoveryFailure(error)
      }
    } else {
      journal = nil
    }
    try Task.checkCancellation()
    try requireSession(sessionID)
    if let journal { try GatewayRunRecoveryValidation.snapshot(journal, runID: request.runID) }
    let disposition: GatewayRunRecoveryDisposition
    // Re-read after the durable lookup's suspension: an active run may have finished meanwhile.
    if let state = runs[request.runID] {
      disposition = .resident(
        snapshot: GatewayRunSnapshot(
          runID: request.runID, invocationID: state.invocationID, phase: state.phase,
          latestSequence: state.latestSequence),
        minimumReplaySequence: state.retainedRecords.first.map { $0.sequence - 1 }
          ?? state.latestSequence,
        journal: journal)
    } else if let journal {
      disposition = .journaled(journal)
    } else if historyReader != nil {
      disposition = .unknown
    } else {
      throw GatewayFailure(
        code: .recoveryUnavailable,
        message: "The gateway has no durable recovery reader. No run was started.")
    }
    let response = GatewayRunRecoveryResponse(
      gatewayInstanceID: gatewayInstanceID, runID: request.runID, disposition: disposition)
    try GatewayRunRecoveryValidation.response(
      response, runID: request.runID, instanceID: gatewayInstanceID)
    return try codec.roundTrip(response)
  }

  public func readRunHistory(_ untrusted: GatewayRunHistoryRequest, sessionID: GatewaySessionID)
    async throws -> GatewayRunHistoryPage
  {
    try Task.checkCancellation()
    let request = try codec.roundTrip(untrusted)
    try requireSession(sessionID)
    try GatewayRunRecoveryValidation.request(request)
    guard let historyReader else {
      throw GatewayFailure(
        code: .recoveryUnavailable, message: "Durable run history is unavailable.")
    }
    let snapshot: GatewayJournalRunSnapshot?
    do { snapshot = try await historyReader.snapshot(for: request.runID) } catch {
      try requireSession(sessionID)
      throw recoveryFailure(error)
    }
    try Task.checkCancellation()
    try requireSession(sessionID)
    try validateHistorySnapshot(snapshot, for: request)
    let records: [AgentEventRecord]
    do {
      records = try await historyReader.records(
        for: request.runID, after: request.afterSequence, through: request.throughSequence,
        limit: request.limit, maximumBytes: configuration.maximumWireBytes)
    } catch {
      try requireSession(sessionID)
      throw recoveryFailure(error)
    }
    try Task.checkCancellation()
    try requireSession(sessionID)
    let refreshed: GatewayJournalRunSnapshot?
    do { refreshed = try await historyReader.snapshot(for: request.runID) } catch {
      try requireSession(sessionID)
      throw recoveryFailure(error)
    }
    try Task.checkCancellation()
    try requireSession(sessionID)
    try validateHistorySnapshot(refreshed, for: request)
    guard records.count <= request.limit else {
      throw GatewayRunRecoveryValidation.malformedHistory()
    }
    // Validate the complete reader prefix before selecting a smaller wire-bounded prefix. Invalid
    // later records cannot be hidden by choosing a page that happens to stop before them.
    let complete = historyPage(request: request, records: records)
    try GatewayRunRecoveryValidation.page(complete, request: request, instanceID: gatewayInstanceID)
    var selected: [AgentEventRecord] = []
    for record in records {
      let candidate = historyPage(request: request, records: selected + [record])
      do {
        let body = try codec.encode(candidate)
        _ = try codec.encode(GatewayXPCResponseEnvelope(operation: .readRunHistory, body: body))
      } catch let failure as GatewayFailure where failure.code == .payloadTooLarge {
        guard !selected.isEmpty else { throw failure }
        break
      }
      selected.append(record)
    }
    let page = historyPage(request: request, records: selected)
    try GatewayRunRecoveryValidation.page(page, request: request, instanceID: gatewayInstanceID)
    return try codec.roundTrip(page)
  }

  private func validateHistorySnapshot(
    _ snapshot: GatewayJournalRunSnapshot?, for request: GatewayRunHistoryRequest
  ) throws {
    guard let snapshot else {
      throw GatewayFailure(
        code: .runNotFound, message: "The durable run was not found. No run was started.")
    }
    try GatewayRunRecoveryValidation.snapshot(snapshot, runID: request.runID)
    guard snapshot.firstEventID == request.firstEventID,
      request.throughSequence <= snapshot.latestSequence
    else {
      throw GatewayFailure(
        code: .invalidCursor, message: "The durable history identity or high-water changed.")
    }
  }

  private func historyPage(request: GatewayRunHistoryRequest, records: [AgentEventRecord])
    -> GatewayRunHistoryPage
  {
    let last = records.last?.sequence ?? request.afterSequence
    return GatewayRunHistoryPage(
      gatewayInstanceID: gatewayInstanceID, runID: request.runID,
      firstEventID: request.firstEventID, afterSequence: request.afterSequence,
      throughSequence: request.throughSequence, records: records,
      nextAfterSequence: last < request.throughSequence ? last : nil)
  }

  private func recoveryFailure(_ error: any Error) -> any Error {
    if error is CancellationError || Task.isCancelled { return CancellationError() }
    if let failure = error as? GatewayFailure { return failure }
    return GatewayFailure(
      code: .recoveryUnavailable,
      message: "The durable journal could not be read safely. No run was restarted.")
  }
}
