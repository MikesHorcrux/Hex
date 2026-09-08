public struct ToolResult: Codable, Equatable, Sendable {
  public let toolCallID: ToolCallID
  public let status: ToolResultStatus
  public let output: JSONValue
  public let content: [ToolResultContent]
  /// Immutable output stored by Hex, not model-supplied filesystem paths.
  public let artifacts: [ArtifactReference]
  /// The tool has a known result, but continuing autonomously is unsafe. The runtime must persist
  /// this receipt and stop before another tool execution or inference request.
  public let requiresUserAttention: Bool
  /// Set only by Hex's runtime or journal recovery for a definitely never-dispatched call.
  public let notExecutedReason: ToolNonExecutionReason?

  public var hasValidNonExecutionMetadata: Bool {
    notExecutedReason == nil
      || (status == .failure && content.isEmpty && artifacts.isEmpty && !requiresUserAttention)
  }

  public init(
    toolCallID: ToolCallID,
    status: ToolResultStatus,
    output: JSONValue,
    content: [ToolResultContent] = [],
    artifacts: [ArtifactReference] = [],
    requiresUserAttention: Bool = false,
    notExecutedReason: ToolNonExecutionReason? = nil
  ) {
    self.toolCallID = toolCallID
    self.status = status
    self.output = output
    self.content = content
    self.artifacts = artifacts
    self.requiresUserAttention = requiresUserAttention
    self.notExecutedReason = notExecutedReason
  }

  private enum CodingKeys: String, CodingKey {
    case toolCallID
    case status
    case output
    case content
    case artifacts
    case requiresUserAttention
    case notExecutedReason
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    toolCallID = try container.decode(ToolCallID.self, forKey: .toolCallID)
    status = try container.decode(ToolResultStatus.self, forKey: .status)
    output = try container.decode(JSONValue.self, forKey: .output)
    content = try container.decodeIfPresent([ToolResultContent].self, forKey: .content) ?? []
    artifacts = try container.decodeIfPresent([ArtifactReference].self, forKey: .artifacts) ?? []
    requiresUserAttention =
      try container.decodeIfPresent(Bool.self, forKey: .requiresUserAttention) ?? false
    notExecutedReason =
      try container.decodeIfPresent(ToolNonExecutionReason.self, forKey: .notExecutedReason)
    guard hasValidNonExecutionMetadata else {
      throw DecodingError.dataCorruptedError(
        forKey: .notExecutedReason, in: container,
        debugDescription:
          "A not-executed receipt cannot claim success, output artifacts or rich content.")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    guard hasValidNonExecutionMetadata else {
      throw EncodingError.invalidValue(
        self,
        .init(
          codingPath: encoder.codingPath,
          debugDescription: "A not-executed receipt has contradictory execution metadata."))
    }
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(toolCallID, forKey: .toolCallID)
    try container.encode(status, forKey: .status)
    try container.encode(output, forKey: .output)
    if !content.isEmpty {
      try container.encode(content, forKey: .content)
    }
    if !artifacts.isEmpty {
      try container.encode(artifacts, forKey: .artifacts)
    }
    if requiresUserAttention {
      try container.encode(true, forKey: .requiresUserAttention)
    }
    try container.encodeIfPresent(notExecutedReason, forKey: .notExecutedReason)
  }
}
