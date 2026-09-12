import Foundation

public struct ToolExecutionContext: Codable, Equatable, Sendable {
  public let runID: AgentRunID
  public let workingDirectory: URL?
  /// Host-selected output references visible in this conversation. Tool arguments cannot add grants.
  public let artifacts: [ArtifactReference]

  public init(
    runID: AgentRunID,
    workingDirectory: URL? = nil,
    artifacts: [ArtifactReference] = []
  ) {
    self.runID = runID
    self.workingDirectory = workingDirectory
    self.artifacts = artifacts
  }

  private enum CodingKeys: String, CodingKey {
    case runID, workingDirectory, artifacts
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    runID = try values.decode(AgentRunID.self, forKey: .runID)
    workingDirectory = try values.decodeIfPresent(URL.self, forKey: .workingDirectory)
    artifacts = try values.decodeIfPresent([ArtifactReference].self, forKey: .artifacts) ?? []
  }

  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(runID, forKey: .runID)
    try values.encodeIfPresent(workingDirectory, forKey: .workingDirectory)
    if !artifacts.isEmpty { try values.encode(artifacts, forKey: .artifacts) }
  }
}
