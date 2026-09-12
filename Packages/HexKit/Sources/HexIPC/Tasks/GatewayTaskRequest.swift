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
  case control(id: UUID, revision: Int64, operationID: UUID, action: Action)

  public enum Action: Codable, Equatable, Sendable {
    case pause, resume, cancel
    case steer(String)
    /// An explicit user observation/decision. Original uncertain receipts remain untouched.
    case reconcile(String)
  }
  public struct Response: Codable, Equatable, Sendable {
    public var activeTask: AgentTaskRecord?
    public var timeline: [ConversationTimelineEntry] = []
    public var before: Int64?
    public var attempts: [AgentTaskAttempt] = []
    public var tasks: [AgentTaskRecord]
    public var schedulerFailure: String?
    public var next: UUID?
    public init(tasks: [AgentTaskRecord] = [], next: UUID? = nil) {
      self.tasks = tasks
      self.next = next
    }
  }
}
