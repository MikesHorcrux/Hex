import Foundation
import HexCore

public struct HostToolExecutor: ToolExecutor, Sendable {
  private let definitions: [ToolDefinition]
  private let toolsByName: [String: any HostTool]

  public init(tools: [any HostTool]) throws {
    guard tools.count <= 4_096 else {
      throw HostToolExecutorError.invalidDefinition
    }
    var definitions: [ToolDefinition] = []
    var toolsByName: [String: any HostTool] = [:]
    definitions.reserveCapacity(tools.count)
    toolsByName.reserveCapacity(tools.count)
    for tool in tools {
      let definition = tool.definition
      guard
        Self.isValidName(definition.name),
        !definition.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        definition.description.utf8.count <= 4_096,
        !definition.description.contains("\0"),
        let schemaBytes = try? JSONEncoder().encode(definition.inputSchema),
        schemaBytes.count <= 64 * 1_024
      else {
        throw HostToolExecutorError.invalidDefinition
      }
      guard toolsByName[definition.name] == nil else {
        throw HostToolExecutorError.duplicateName
      }
      definitions.append(definition)
      toolsByName[definition.name] = tool
    }
    self.definitions = definitions.sorted { $0.name < $1.name }
    self.toolsByName = toolsByName
  }

  public func availableTools() async throws -> [ToolDefinition] {
    try Task.checkCancellation()
    return definitions
  }

  public func authorizationRequest(
    for call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> AuthorizationRequest {
    try Task.checkCancellation()
    guard let tool = toolsByName[call.name] else {
      throw HostToolExecutorError.unknownTool
    }
    return try await tool.authorizationRequest(for: call, in: context)
  }

  public func execute(
    _ call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> ToolResult {
    try Task.checkCancellation()
    guard let tool = toolsByName[call.name] else {
      throw HostToolExecutorError.unknownTool
    }
    let result = try await tool.execute(call, in: context)
    guard result.toolCallID == call.id else {
      throw HostToolExecutorError.invalidDefinition
    }
    return result
  }

  private static func isValidName(_ value: String) -> Bool {
    !value.isEmpty
      && value.utf8.count <= 128
      && value.utf8.allSatisfy { byte in
        (48...57).contains(byte)
          || (65...90).contains(byte)
          || (97...122).contains(byte)
          || byte == 45
          || byte == 46
          || byte == 95
      }
  }
}
