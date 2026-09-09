import Foundation

public protocol ProcessSessionStorage: Sendable {
  func processScope(for runID: AgentRunID, workspace: URL) async throws -> ProcessSessionScope
  func processSession(_ id: UUID) async throws -> ProcessSessionRecord?
  func processSessions(conversationID: UUID?, before: UUID?, limit: Int) async throws
    -> [ProcessSessionRecord]
  func saveProcessSession(_ record: ProcessSessionRecord) async throws -> ProcessSessionRecord
  func processOperation(_ id: String) async throws -> ProcessSessionOperation?
  func saveProcessOperation(_ operation: ProcessSessionOperation) async throws
  func appendProcessSegment(_ segment: ProcessOutputSegment) async throws -> ProcessSessionRecord
  func processSegments(_ id: UUID, offset: Int64, limit: Int) async throws -> [ProcessOutputSegment]
  func interruptProcessSessions() async throws
}
