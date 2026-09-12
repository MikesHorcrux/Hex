import Foundation
import HexCore

public struct GatewayTaskResponse: Codable, Equatable, Sendable {
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
