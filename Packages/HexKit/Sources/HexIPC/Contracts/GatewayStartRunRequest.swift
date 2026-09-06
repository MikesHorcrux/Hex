import Foundation
import HexCore

public struct GatewayStartRunRequest: Codable, Equatable, Sendable {
  public let runID: AgentRunID
  public let modelID: ModelID
  public let initialMessages: [Message]
  public let options: InferenceOptions
  public let toolChoice: ToolChoice

  /// A requested working-directory identity, not a grant of filesystem authority. The same-process
  /// transport remains constrained by the app sandbox and does not expand file access.
  public let workingDirectory: URL?

  /// Immutable output references retained outside compacted conversation prose. This inventory
  /// carries no paths and does not replace the resident reader's exact stored-manifest check.
  public let availableArtifacts: [ArtifactReference]
  /// An explicit user choice pinned to this run. Nil preserves the resident's configured default;
  /// this authority is never inferred from conversation text or tool arguments.
  public let authorizationMode: HexAuthorizationMode?

  public init(
    runID: AgentRunID,
    modelID: ModelID,
    initialMessages: [Message],
    options: InferenceOptions = InferenceOptions(),
    toolChoice: ToolChoice = .automatic,
    workingDirectory: URL? = nil,
    availableArtifacts: [ArtifactReference] = [],
    authorizationMode: HexAuthorizationMode? = nil
  ) {
    self.runID = runID
    self.modelID = modelID
    self.initialMessages = initialMessages
    self.options = options
    self.toolChoice = toolChoice
    self.workingDirectory = workingDirectory
    self.availableArtifacts = availableArtifacts
    self.authorizationMode = authorizationMode
  }

  private enum CodingKeys: String, CodingKey {
    case runID, modelID, initialMessages, options, toolChoice, workingDirectory, availableArtifacts
    case authorizationMode
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    runID = try values.decode(AgentRunID.self, forKey: .runID)
    modelID = try values.decode(ModelID.self, forKey: .modelID)
    initialMessages = try values.decode([Message].self, forKey: .initialMessages)
    options = try values.decode(InferenceOptions.self, forKey: .options)
    toolChoice = try values.decode(ToolChoice.self, forKey: .toolChoice)
    workingDirectory = try values.decodeIfPresent(URL.self, forKey: .workingDirectory)
    availableArtifacts =
      try values.decodeIfPresent([ArtifactReference].self, forKey: .availableArtifacts) ?? []
    authorizationMode = try values.decodeIfPresent(
      HexAuthorizationMode.self, forKey: .authorizationMode)
    try ToolArtifactValidation.validate(availableArtifacts)
  }

  public func encode(to encoder: any Encoder) throws {
    try ToolArtifactValidation.validate(availableArtifacts)
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(runID, forKey: .runID)
    try values.encode(modelID, forKey: .modelID)
    try values.encode(initialMessages, forKey: .initialMessages)
    try values.encode(options, forKey: .options)
    try values.encode(toolChoice, forKey: .toolChoice)
    try values.encodeIfPresent(workingDirectory, forKey: .workingDirectory)
    try values.encodeIfPresent(authorizationMode, forKey: .authorizationMode)
    if !availableArtifacts.isEmpty {
      try values.encode(availableArtifacts, forKey: .availableArtifacts)
    }
  }
}
