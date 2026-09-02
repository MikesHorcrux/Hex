import Foundation

/// Non-secret settings needed to start Hex's resident runtime.
///
/// Credentials intentionally do not belong in this value or its Codable representation. The
/// workspace is represented as an absolute file URL so a persisted setting cannot silently depend
/// on the process's current directory.
public struct HexResidentRuntimeSettings: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  public let modelID: String
  public let workspaceRoot: URL
  public let mcpServers: [HexResidentMCPServerSettings]

  public init(
    modelID: String,
    workspaceRoot: URL,
    mcpServers: [HexResidentMCPServerSettings] = [],
    schemaVersion: Int = Self.currentSchemaVersion
  ) throws {
    guard schemaVersion == Self.currentSchemaVersion else {
      throw HexResidentRuntimeSettingsError.unsupportedSchemaVersion(schemaVersion)
    }
    guard Self.isPrintableASCII(modelID), modelID.utf8.count <= 512 else {
      throw HexResidentRuntimeSettingsError.invalidModelID
    }
    guard Self.isAbsoluteWorkspaceURL(workspaceRoot) else {
      throw HexResidentRuntimeSettingsError.invalidWorkspaceRoot
    }
    guard
      mcpServers.count <= 16,
      Set(mcpServers.map(\.serverID)).count == mcpServers.count
    else {
      throw HexResidentRuntimeSettingsError.invalidMCPServers
    }

    self.schemaVersion = schemaVersion
    self.modelID = modelID
    self.workspaceRoot = workspaceRoot.standardizedFileURL
    self.mcpServers = mcpServers.sorted { $0.serverID < $1.serverID }
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case modelID
    case workspaceRoot
    case mcpServers
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    let modelID = try container.decode(String.self, forKey: .modelID)
    let workspaceRoot = try container.decode(URL.self, forKey: .workspaceRoot)
    let mcpServers =
      try container.decodeIfPresent(
        [HexResidentMCPServerSettings].self,
        forKey: .mcpServers
      ) ?? []
    try self.init(
      modelID: modelID,
      workspaceRoot: workspaceRoot,
      mcpServers: mcpServers,
      schemaVersion: schemaVersion
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(modelID, forKey: .modelID)
    try container.encode(workspaceRoot, forKey: .workspaceRoot)
    try container.encode(mcpServers, forKey: .mcpServers)
  }

  private static func isPrintableASCII(_ value: String) -> Bool {
    let bytes = value.utf8
    guard !bytes.isEmpty else {
      return false
    }
    return bytes.allSatisfy { byte in
      (0x21...0x7E).contains(byte)
    }
  }

  private static func isAbsoluteWorkspaceURL(_ url: URL) -> Bool {
    let path = url.path
    return url.isFileURL
      && !path.isEmpty
      && path.hasPrefix("/")
      && path.utf8.count <= 4_096
      && !path.contains("\0")
  }
}
