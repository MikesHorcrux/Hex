import Foundation

/// Only the resident scheduler writes task records. Saves are atomic optimistic transactions.
public protocol AgentTaskStorage: Sendable {
  func readTask(_ id: UUID) async throws -> AgentTaskRecord?
  func listTasks(after: UUID?, limit: Int, unfinishedOnly: Bool) async throws -> [AgentTaskRecord]
  func taskAttempts(_ id: UUID, before: Int?, limit: Int) async throws -> [AgentTaskAttempt]
  func saveTask(_ record: AgentTaskRecord) async throws -> AgentTaskRecord
}
