import Foundation
import HexCore

extension HexGatewayService {
  func conversationContext(after input: AgentTaskRecord) async throws -> GatewayStartRunRequest {
    guard let taskStore else { throw AgentTaskStorageError.unavailable }
    var record = input
    var visited: Set<UUID> = []
    while record.phase == .cancelled && record.attemptCount == 0 {
      try Task.checkCancellation()
      guard visited.insert(record.id).inserted else { throw AgentTaskStorageError.invalidRecord }
      guard let priorID = record.predecessorID else {
        let source = try codec.decode(GatewayStartRunRequest.self, from: record.request)
        return continuationRequest(source, messages: Array(source.initialMessages.dropLast()))
      }
      guard let prior = try await taskStore.readTask(priorID), prior.phase.isTerminal,
        prior.conversationID == input.conversationID
      else { throw AgentTaskStorageError.invalidRecord }
      record = prior
    }
    return try codec.decode(GatewayStartRunRequest.self, from: record.request)
  }
}
