import Foundation

public struct AgentTaskInstruction: Codable, Equatable, Sendable {
  public let id: UUID
  public let text: String
  public init(id: UUID, text: String) {
    self.id = id
    self.text = text
  }
}
