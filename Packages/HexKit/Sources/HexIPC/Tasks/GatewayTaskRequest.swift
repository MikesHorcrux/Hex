import Foundation
import HexCore

public enum GatewayTaskRequest: Codable, Equatable, Sendable {
  case submit(id: UUID, title: String, request: GatewayStartRunRequest)
  case submitConversation(
    id: UUID, conversationID: UUID, predecessorID: UUID?, title: String,
    request: GatewayStartRunRequest)
  case adoptLegacyConversation(UUID)
  case conversationTasks(UUID, before: UUID?, limit: Int)
  case conversationHistory(UUID, before: Int64?, limit: Int)
  case list(after: UUID?, limit: Int)
  case read(UUID)
  case attempts(UUID, before: Int?, limit: Int)
  case control(id: UUID, revision: Int64, operationID: UUID, action: GatewayTaskAction)

}
