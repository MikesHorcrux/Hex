import HexCore

public struct MCPRemoteTool: Equatable, Sendable {
  public let name: String
  public let description: String?
  public let inputSchema: [String: JSONValue]
  public let taskSupport: MCPToolTaskSupport
  public let supportsTaskAugmentedToolCalls: Bool

  public init(
    name: String,
    description: String? = nil,
    inputSchema: [String: JSONValue],
    taskSupport: MCPToolTaskSupport = .forbidden,
    supportsTaskAugmentedToolCalls: Bool = false
  ) {
    self.name = name
    self.description = description
    self.inputSchema = inputSchema
    self.taskSupport = taskSupport
    self.supportsTaskAugmentedToolCalls = supportsTaskAugmentedToolCalls
  }

  var requiresTaskExecution: Bool {
    supportsTaskAugmentedToolCalls && taskSupport == .required
  }
}
