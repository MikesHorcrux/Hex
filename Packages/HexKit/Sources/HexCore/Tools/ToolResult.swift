public struct ToolResult: Codable, Equatable, Sendable {
  public let toolCallID: ToolCallID
  public let status: ToolResultStatus
  public let output: JSONValue
  public let content: [ToolResultContent]

  public init(
    toolCallID: ToolCallID,
    status: ToolResultStatus,
    output: JSONValue,
    content: [ToolResultContent] = []
  ) {
    self.toolCallID = toolCallID
    self.status = status
    self.output = output
    self.content = content
  }

  private enum CodingKeys: String, CodingKey {
    case toolCallID
    case status
    case output
    case content
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    toolCallID = try container.decode(ToolCallID.self, forKey: .toolCallID)
    status = try container.decode(ToolResultStatus.self, forKey: .status)
    output = try container.decode(JSONValue.self, forKey: .output)
    content = try container.decodeIfPresent([ToolResultContent].self, forKey: .content) ?? []
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(toolCallID, forKey: .toolCallID)
    try container.encode(status, forKey: .status)
    try container.encode(output, forKey: .output)
    if !content.isEmpty {
      try container.encode(content, forKey: .content)
    }
  }
}
