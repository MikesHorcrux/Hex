import Foundation

/// Persisted, non-secret MCP server settings.
///
/// HTTP credentials are deliberately excluded. A composition root may inject process-only headers
/// from a secret store through `MCPHTTPHeaderProvider`.
public struct HexResidentMCPServerSettings: Codable, Equatable, Sendable {
  public let serverID: String
  public let transport: HexResidentMCPTransport
  public let endpointURL: URL?
  public let isEnabled: Bool
  public let requiresBearerToken: Bool
  public let executableURL: URL?
  public let arguments: [String]
  public let workingDirectory: URL?

  public init(
    serverID: String,
    transport: HexResidentMCPTransport,
    endpointURL: URL? = nil,
    isEnabled: Bool = true,
    requiresBearerToken: Bool = false,
    executableURL: URL? = nil,
    arguments: [String] = [],
    workingDirectory: URL? = nil
  ) throws {
    guard Self.isValidServerID(serverID) else {
      throw HexResidentRuntimeSettingsError.invalidMCPServers
    }
    if transport != .stdio,
      executableURL != nil || !arguments.isEmpty || workingDirectory != nil
    {
      throw HexResidentRuntimeSettingsError.invalidMCPServers
    }
    if transport != .streamableHTTP && requiresBearerToken {
      throw HexResidentRuntimeSettingsError.invalidMCPServers
    }
    switch transport {
    case .peekaboo:
      guard serverID == "peekaboo", endpointURL == nil else {
        throw HexResidentRuntimeSettingsError.invalidMCPServers
      }
    case .playwright:
      guard serverID == "playwright", endpointURL == nil else {
        throw HexResidentRuntimeSettingsError.invalidMCPServers
      }
    case .xcode:
      guard serverID == "xcode", endpointURL == nil else {
        throw HexResidentRuntimeSettingsError.invalidMCPServers
      }
    case .streamableHTTP:
      guard let endpointURL, Self.isValidEndpoint(endpointURL) else {
        throw HexResidentRuntimeSettingsError.invalidMCPServers
      }
    case .stdio:
      guard endpointURL == nil,
        !["peekaboo", "playwright", "xcode"].contains(serverID),
        let executableURL, Self.isValidFileURL(executableURL),
        let workingDirectory, Self.isValidFileURL(workingDirectory),
        Self.isValidArguments(arguments)
      else {
        throw HexResidentRuntimeSettingsError.invalidMCPServers
      }
    }
    self.serverID = serverID
    self.transport = transport
    self.endpointURL = endpointURL
    self.isEnabled = isEnabled
    self.requiresBearerToken = requiresBearerToken
    self.executableURL = executableURL
    self.arguments = arguments
    self.workingDirectory = workingDirectory
  }

  public static func xcode(isEnabled: Bool = true) throws -> Self {
    try Self(serverID: "xcode", transport: .xcode, isEnabled: isEnabled)
  }

  public static func playwright(isEnabled: Bool = true) throws -> Self {
    try Self(serverID: "playwright", transport: .playwright, isEnabled: isEnabled)
  }

  public static func peekaboo(isEnabled: Bool = true) throws -> Self {
    try Self(serverID: "peekaboo", transport: .peekaboo, isEnabled: isEnabled)
  }

  private enum CodingKeys: String, CodingKey {
    case serverID
    case transport
    case endpointURL
    case isEnabled
    case requiresBearerToken
    case executableURL
    case arguments
    case workingDirectory
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      serverID: container.decode(String.self, forKey: .serverID),
      transport: container.decode(HexResidentMCPTransport.self, forKey: .transport),
      endpointURL: container.decodeIfPresent(URL.self, forKey: .endpointURL),
      isEnabled: container.decode(Bool.self, forKey: .isEnabled),
      requiresBearerToken: container.decodeIfPresent(Bool.self, forKey: .requiresBearerToken)
        ?? false,
      executableURL: container.decodeIfPresent(URL.self, forKey: .executableURL),
      arguments: container.decodeIfPresent([String].self, forKey: .arguments) ?? [],
      workingDirectory: container.decodeIfPresent(URL.self, forKey: .workingDirectory)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(serverID, forKey: .serverID)
    try container.encode(transport, forKey: .transport)
    try container.encodeIfPresent(endpointURL, forKey: .endpointURL)
    try container.encode(isEnabled, forKey: .isEnabled)
    try container.encode(requiresBearerToken, forKey: .requiresBearerToken)
    try container.encodeIfPresent(executableURL, forKey: .executableURL)
    if !arguments.isEmpty { try container.encode(arguments, forKey: .arguments) }
    try container.encodeIfPresent(workingDirectory, forKey: .workingDirectory)
  }

  private static func isValidFileURL(_ url: URL) -> Bool {
    url.isFileURL && url.path.hasPrefix("/") && url.path.utf8.count <= 4_096
      && !url.path.contains("\0") && url.query == nil && url.fragment == nil
      && url.user == nil && url.password == nil
      && (url.host == nil || url.host == "" || url.host == "localhost")
  }

  private static func isValidArguments(_ arguments: [String]) -> Bool {
    guard arguments.count <= 256 else { return false }
    var totalBytes = 0
    for argument in arguments {
      guard !argument.contains("\0"), argument.utf8.count <= 64 * 1_024 else { return false }
      totalBytes += argument.utf8.count + 1
      guard totalBytes <= 256 * 1_024 else { return false }
    }
    return true
  }

  private static func isValidServerID(_ value: String) -> Bool {
    !value.isEmpty
      && value.utf8.count <= 32
      && value.utf8.allSatisfy { byte in
        (48...57).contains(byte)
          || (97...122).contains(byte)
          || byte == 45
          || byte == 95
      }
  }

  private static func isValidEndpoint(_ url: URL) -> Bool {
    guard
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased(),
      let host = components.host?.lowercased(),
      !host.isEmpty,
      components.user == nil,
      components.password == nil,
      components.fragment == nil,
      components.query == nil,
      url.absoluteString.utf8.count <= 4_096,
      !url.absoluteString.contains("\0")
    else {
      return false
    }
    if let port = components.port, !(1...65_535).contains(port) {
      return false
    }
    if scheme == "https" { return true }
    return scheme == "http" && ["127.0.0.1", "::1", "localhost"].contains(host)
  }
}
