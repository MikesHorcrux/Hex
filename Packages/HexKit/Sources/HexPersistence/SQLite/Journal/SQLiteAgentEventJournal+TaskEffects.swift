import Foundation
import HexCore

extension SQLiteAgentEventJournal: AgentTaskEffectReading {
  public func previousTaskEffect(runID: AgentRunID, fingerprint: Data) throws -> AgentTaskEffect? {
    let connection = try requireConnection()
    let statement = try connection.prepare(
      """
      SELECT effect.run_id, effect.call_id, effect.result, effect.result IS NULL
      FROM agent_task_effects AS effect
      JOIN agent_task_attempts AS prior ON prior.run_id = effect.run_id
      JOIN agent_task_attempts AS current ON current.task_id = prior.task_id
      WHERE current.run_id = ? AND effect.fingerprint = ? AND prior.attempt < current.attempt
      ORDER BY prior.attempt ASC LIMIT 1
      """)
    try statement.bind(runID.rawValue.uuidString, at: 1)
    try statement.bind(fingerprint, at: 2)
    guard try statement.step() == .row else { return nil }
    let text = try statement.columnText(at: 0, maximumBytes: 36)
    guard let id = UUID(uuidString: text) else { throw AgentTaskStorageError.invalidRecord }
    let result: ToolResult? =
      try statement.columnInt64(at: 3) == 1
      ? nil
      : JSONDecoder().decode(
        ToolResult.self,
        from: statement.columnBlob(
          at: 2,
          maximumBytes: configuration.maximumPayloadBytes))
    return AgentTaskEffect(
      runID: AgentRunID(rawValue: id),
      callID: ToolCallID(
        rawValue: try statement.columnText(at: 1, maximumBytes: configuration.maximumTextBytes)),
      result: result)
  }

  func recordTaskEffect(_ event: AgentEvent, runID: AgentRunID, connection: SQLiteConnection) throws
  {
    switch event {
    case .toolStarted(let call):
      let statement = try connection.prepare(
        """
        INSERT INTO agent_task_effects (run_id, call_id, fingerprint)
        SELECT ?, ?, ? WHERE EXISTS (SELECT 1 FROM agent_task_attempts WHERE run_id = ?)
        """)
      try statement.bind(runID.rawValue.uuidString, at: 1)
      try statement.bind(call.id.rawValue, at: 2)
      try statement.bind(AgentTaskOperationFingerprint.data(for: call), at: 3)
      try statement.bind(runID.rawValue.uuidString, at: 4)
      _ = try statement.step()
    case .toolFinished(let result):
      let statement = try connection.prepare(
        """
        UPDATE agent_task_effects SET result = ? WHERE run_id = ? AND call_id = ?
        """)
      try statement.bind(JSONEncoder().encode(result), at: 1)
      try statement.bind(runID.rawValue.uuidString, at: 2)
      try statement.bind(result.toolCallID.rawValue, at: 3)
      _ = try statement.step()
    default: break
    }
  }
}
