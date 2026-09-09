import Foundation

public protocol ProcessSessionControlling: Sendable {
  func list(conversationID: UUID, before: UUID?, limit: Int) async throws -> [ProcessSessionRecord]
  func read(_ id: UUID, conversationID: UUID, offset: Int64, maximumBytes: Int) async throws
    -> ProcessSessionPage
  func command(_ command: ProcessSessionCommand, conversationID: UUID) async throws
    -> ProcessSessionOperation
  func cancelTask(_ taskID: UUID) async
  func acknowledgeTask(_ taskID: UUID, operationID: UUID) async throws
  func finishTask(_ taskID: UUID, cancelled: Bool) async throws
  func shutdown() async
}
