import Foundation
import HexCore

nonisolated struct ConversationItem: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let role: ConversationItemRole
  var text: String
  let timestamp: Date
  var isStreaming: Bool
  let artifacts: [ArtifactReference]
  let toolCallID: ToolCallID?

  init(
    id: UUID = UUID(),
    role: ConversationItemRole,
    text: String,
    timestamp: Date = Date(),
    isStreaming: Bool = false,
    artifacts: [ArtifactReference] = [],
    toolCallID: ToolCallID? = nil
  ) {
    self.id = id
    self.role = role
    self.text = text
    self.timestamp = timestamp
    self.isStreaming = isStreaming
    self.artifacts = artifacts
    self.toolCallID = toolCallID
  }

  private enum CodingKeys: String, CodingKey {
    case id, role, text, timestamp, isStreaming, artifacts, toolCallID
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    role = try values.decode(ConversationItemRole.self, forKey: .role)
    text = try values.decode(String.self, forKey: .text)
    timestamp = try values.decode(Date.self, forKey: .timestamp)
    isStreaming = try values.decode(Bool.self, forKey: .isStreaming)
    artifacts = try values.decodeIfPresent([ArtifactReference].self, forKey: .artifacts) ?? []
    toolCallID = try values.decodeIfPresent(ToolCallID.self, forKey: .toolCallID)
  }

  func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(id, forKey: .id)
    try values.encode(role, forKey: .role)
    try values.encode(text, forKey: .text)
    try values.encode(timestamp, forKey: .timestamp)
    try values.encode(isStreaming, forKey: .isStreaming)
    if !artifacts.isEmpty { try values.encode(artifacts, forKey: .artifacts) }
    try values.encodeIfPresent(toolCallID, forKey: .toolCallID)
  }
}
