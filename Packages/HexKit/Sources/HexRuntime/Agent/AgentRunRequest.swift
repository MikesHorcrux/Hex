import Foundation
import HexCore

public struct AgentRunRequest: Identifiable, Codable, Equatable, Sendable {
  public var id: AgentRunID { runID }

  public let runID: AgentRunID
  public let modelID: ModelID
  /// Messages supplied by the gateway's trusted context layer. These participate in inference
  /// but are intentionally not journaled as user conversation items.
  public let contextMessages: [Message]
  public let initialMessages: [Message]
  public let options: InferenceOptions
  public let toolChoice: ToolChoice
  public let workingDirectory: URL?
  /// Exact, host-provided references from the preserved conversation, independent of compaction.
  /// References are data, not authority derived from model-generated IDs or filesystem paths.
  public let availableArtifacts: [ArtifactReference]
  /// User/host choice pinned for this run; never inferred from messages or tool arguments.
  public let authorizationMode: HexAuthorizationMode?

  public init(
    runID: AgentRunID,
    modelID: ModelID,
    initialMessages: [Message],
    contextMessages: [Message] = [],
    options: InferenceOptions = InferenceOptions(),
    toolChoice: ToolChoice = .automatic,
    workingDirectory: URL? = nil,
    availableArtifacts: [ArtifactReference] = [],
    authorizationMode: HexAuthorizationMode? = nil
  ) {
    self.runID = runID
    self.modelID = modelID
    self.contextMessages = contextMessages
    self.initialMessages = initialMessages
    self.options = options
    self.toolChoice = toolChoice
    self.workingDirectory = workingDirectory
    self.availableArtifacts = availableArtifacts
    self.authorizationMode = authorizationMode
  }

  private enum CodingKeys: String, CodingKey {
    case runID, modelID, contextMessages, initialMessages, options, toolChoice, workingDirectory
    case availableArtifacts, authorizationMode
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    runID = try values.decode(AgentRunID.self, forKey: .runID)
    modelID = try values.decode(ModelID.self, forKey: .modelID)
    contextMessages = try values.decode([Message].self, forKey: .contextMessages)
    initialMessages = try values.decode([Message].self, forKey: .initialMessages)
    options = try values.decode(InferenceOptions.self, forKey: .options)
    toolChoice = try values.decode(ToolChoice.self, forKey: .toolChoice)
    workingDirectory = try values.decodeIfPresent(URL.self, forKey: .workingDirectory)
    availableArtifacts =
      try values.decodeIfPresent([ArtifactReference].self, forKey: .availableArtifacts) ?? []
    try ToolArtifactValidation.validate(availableArtifacts)
    authorizationMode = try values.decodeIfPresent(
      HexAuthorizationMode.self, forKey: .authorizationMode)
  }

  public func encode(to encoder: any Encoder) throws {
    try ToolArtifactValidation.validate(availableArtifacts)
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(runID, forKey: .runID)
    try values.encode(modelID, forKey: .modelID)
    try values.encode(contextMessages, forKey: .contextMessages)
    try values.encode(initialMessages, forKey: .initialMessages)
    try values.encode(options, forKey: .options)
    try values.encode(toolChoice, forKey: .toolChoice)
    try values.encodeIfPresent(workingDirectory, forKey: .workingDirectory)
    if !availableArtifacts.isEmpty {
      try values.encode(availableArtifacts, forKey: .availableArtifacts)
    }
    try values.encodeIfPresent(authorizationMode, forKey: .authorizationMode)
  }
}
