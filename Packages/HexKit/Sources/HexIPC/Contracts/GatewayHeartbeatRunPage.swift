import Foundation

public struct GatewayHeartbeatRunPage: Codable, Equatable, Sendable {
  public let storeID: UUID
  public let runs: [GatewayHeartbeatRun]
  public let nextCursor: GatewayHeartbeatRunCursor?

  public init(
    storeID: UUID, runs: [GatewayHeartbeatRun], nextCursor: GatewayHeartbeatRunCursor? = nil
  ) {
    self.storeID = storeID
    self.runs = runs
    self.nextCursor = nextCursor
  }

  public func validated() throws -> Self {
    try GatewayRunRecoveryValidation.identity(storeID)
    guard runs.count <= 64 else { throw Self.malformed() }
    var occurrences: [UUID: Set<Date>] = [:]
    var runIDs = Set<UUID>()
    for run in runs {
      _ = try run.validated()
      guard occurrences[run.scheduleID, default: []].insert(run.dueAt).inserted else {
        throw Self.malformed()
      }
      if let runID = run.runID, !runIDs.insert(runID.rawValue).inserted { throw Self.malformed() }
    }
    if let nextCursor {
      _ = try nextCursor.validated()
      guard !runs.isEmpty, nextCursor.storeID == storeID else { throw Self.malformed() }
    }
    return self
  }

  public func validated(for request: GatewayHeartbeatRunListRequest) throws -> Self {
    _ = try request.validated()
    _ = try validated()
    if let cursor = request.cursor, cursor.storeID != storeID { throw Self.malformed() }
    guard runs.count <= request.limit,
      request.scheduleID == nil || runs.allSatisfy({ $0.scheduleID == request.scheduleID })
    else { throw Self.malformed() }
    if let nextCursor {
      guard nextCursor.scheduleID == request.scheduleID else { throw Self.malformed() }
      if let previous = request.cursor {
        guard nextCursor.storeID == previous.storeID,
          nextCursor.highWaterSequence == previous.highWaterSequence,
          nextCursor.beforeSequence < previous.beforeSequence
        else { throw Self.malformed() }
      }
    }
    return self
  }

  private static func malformed() -> GatewayFailure {
    GatewayFailure(
      code: .malformedPayload, message: "The scheduled run history page is inconsistent.")
  }
}
