import Foundation

public struct MCPStreamableHTTPServerConfiguration: Sendable {
  public let serverID: String
  public let endpointURL: URL
  public let clientName: String
  public let clientVersion: String
  public let requestTimeoutMilliseconds: UInt64
  public let maximumMessageBytes: Int
  public let maximumToolPages: Int
  public let maximumTools: Int
  public let maximumContentItems: Int
  public let maximumArgumentsBytes: Int
  public let maximumSSEEvents: Int

  public init(
    serverID: String,
    endpointURL: URL,
    clientName: String = "Hex",
    clientVersion: String = "0.1.0",
    requestTimeoutMilliseconds: UInt64 = 30_000,
    maximumMessageBytes: Int = 2 * 1_024 * 1_024,
    maximumToolPages: Int = 32,
    maximumTools: Int = 4_096,
    maximumContentItems: Int = 1_024,
    maximumArgumentsBytes: Int = 512 * 1_024,
    maximumSSEEvents: Int = 1_024
  ) throws {
    guard MCPToolCatalogBuilder.isValidServerID(serverID) else {
      throw MCPServerConfigurationError.invalidServerID
    }
    guard Self.isValidEndpoint(endpointURL) else {
      throw MCPServerConfigurationError.invalidEndpoint
    }
    guard
      Self.isValidIdentityPart(clientName),
      Self.isValidIdentityPart(clientVersion)
    else {
      throw MCPServerConfigurationError.invalidClientIdentity
    }
    guard
      (1...300_000).contains(requestTimeoutMilliseconds),
      (1_024...8 * 1_024 * 1_024).contains(maximumMessageBytes),
      (1...128).contains(maximumToolPages),
      (1...4_096).contains(maximumTools),
      (1...4_096).contains(maximumContentItems),
      (1_024...2 * 1_024 * 1_024).contains(maximumArgumentsBytes),
      (1...4_096).contains(maximumSSEEvents)
    else {
      throw MCPServerConfigurationError.invalidLimit
    }

    self.serverID = serverID
    self.endpointURL = endpointURL
    self.clientName = clientName
    self.clientVersion = clientVersion
    self.requestTimeoutMilliseconds = requestTimeoutMilliseconds
    self.maximumMessageBytes = maximumMessageBytes
    self.maximumToolPages = maximumToolPages
    self.maximumTools = maximumTools
    self.maximumContentItems = maximumContentItems
    self.maximumArgumentsBytes = maximumArgumentsBytes
    self.maximumSSEEvents = maximumSSEEvents
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
    guard scheme == "http" else { return false }
    return host == "127.0.0.1" || host == "::1" || host == "localhost"
  }

  private static func isValidIdentityPart(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty
      && trimmed == value
      && value.utf8.count <= 128
      && !value.contains("\0")
  }
}
