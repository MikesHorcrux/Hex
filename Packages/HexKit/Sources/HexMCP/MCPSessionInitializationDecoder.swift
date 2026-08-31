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
    let supportsTaskAugmentedToolCalls = try supportsTaskAugmentedToolCalls(
      capabilities: capabilities,
      protocolVersion: version
    )
    return MCPSessionInitialization(
      protocolVersion: version,
      serverName: serverName,
      serverVersion: serverVersion,
      supportsTaskAugmentedToolCalls: supportsTaskAugmentedToolCalls
    )
  }

  private static func supportsTaskAugmentedToolCalls(
    capabilities: [String: JSONValue],
    protocolVersion: MCPProtocolVersion
  ) throws -> Bool {
    guard protocolVersion == .november2025, let encodedTasks = capabilities["tasks"] else {
      return false
    }
    guard let tasks = encodedTasks.mcpObject else {
      throw MCPClientSessionError.protocolViolation
    }
    guard let encodedRequests = tasks["requests"] else { return false }
    guard let requests = encodedRequests.mcpObject else {
      throw MCPClientSessionError.protocolViolation
    }
    guard let encodedTools = requests["tools"] else { return false }
    guard let tools = encodedTools.mcpObject else {
      throw MCPClientSessionError.protocolViolation
    }
    guard let encodedCall = tools["call"] else { return false }
    guard encodedCall.mcpObject != nil else {
      throw MCPClientSessionError.protocolViolation
    }
    return true
  }

  private static func validIdentity(_ value: String) -> Bool {
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && value.utf8.count <= 256
      && !value.contains("\0")
  }
}
