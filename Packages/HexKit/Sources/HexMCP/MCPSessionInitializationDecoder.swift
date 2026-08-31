import HexCore

enum MCPSessionInitializationDecoder {
  static func decode(_ value: JSONValue) throws -> MCPSessionInitialization {
    guard
      let object = value.mcpObject,
      let versionString = object["protocolVersion"]?.mcpString,
      let version = MCPProtocolVersion(rawValue: versionString),
      let capabilities = object["capabilities"]?.mcpObject,
      capabilities["tools"]?.mcpObject != nil,
      let serverInfo = object["serverInfo"]?.mcpObject,
      let serverName = serverInfo["name"]?.mcpString,
      let serverVersion = serverInfo["version"]?.mcpString,
      validIdentity(serverName),
      validIdentity(serverVersion)
    else {
      if let versionString = value.mcpObject?["protocolVersion"]?.mcpString,
        MCPProtocolVersion(rawValue: versionString) == nil
      {
        throw MCPClientSessionError.unsupportedProtocolVersion
      }
      if value.mcpObject?["capabilities"]?.mcpObject?["tools"]?.mcpObject == nil {
        throw MCPClientSessionError.toolsUnavailable
      }
      throw MCPClientSessionError.protocolViolation
    }
    return MCPSessionInitialization(
      protocolVersion: version,
      serverName: serverName,
      serverVersion: serverVersion
    )
  }

  private static func validIdentity(_ value: String) -> Bool {
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && value.utf8.count <= 256
      && !value.contains("\0")
  }
}
