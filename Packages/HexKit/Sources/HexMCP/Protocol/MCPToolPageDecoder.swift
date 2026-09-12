import Foundation
import HexCore

enum MCPToolPageDecoder {
  static func decode(
    _ value: JSONValue,
    remainingToolCapacity: Int,
    supportsTaskAugmentedToolCalls: Bool
  ) throws -> MCPToolPage {
    guard
      let object = value.mcpObject,
      let encodedTools = object["tools"]?.mcpArray,
      encodedTools.count <= remainingToolCapacity
    else {
      throw MCPClientSessionError.limitExceeded
    }
    let nextCursor: String?
    if let encodedCursor = object["nextCursor"] {
      switch encodedCursor {
      case .null:
        nextCursor = nil
      case .string(let cursor):
        guard !cursor.isEmpty, cursor.utf8.count <= 4_096, !cursor.contains("\0") else {
          throw MCPClientSessionError.protocolViolation
        }
        nextCursor = cursor
      default:
        throw MCPClientSessionError.protocolViolation
      }
    } else {
      nextCursor = nil
    }

    let tools = try encodedTools.map { encodedTool in
      try decodeTool(
        encodedTool,
        supportsTaskAugmentedToolCalls: supportsTaskAugmentedToolCalls
      )
    }
    return MCPToolPage(tools: tools, nextCursor: nextCursor)
  }

  private static func decodeTool(
    _ value: JSONValue,
    supportsTaskAugmentedToolCalls: Bool
  ) throws -> MCPRemoteTool {
    guard
      let object = value.mcpObject,
      let name = object["name"]?.mcpString,
      MCPToolCatalogBuilder.isValidToolName(name),
      let schema = object["inputSchema"]?.mcpObject,
      schema["type"] == .string("object"),
      MCPJSONValueValidator.isValid(
        .object(schema),
        maximumNodes: 10_000,
        maximumStringBytes: 32 * 1_024,
        maximumEstimatedBytes: 64 * 1_024
      ),
      let schemaData = try? JSONEncoder().encode(schema),
      schemaData.count <= 64 * 1_024
    else {
      throw MCPClientSessionError.protocolViolation
    }
    let description: String?
    if let encodedDescription = object["description"] {
      guard
        let decoded = encodedDescription.mcpString,
        decoded.utf8.count <= 4_096,
        !decoded.contains("\0")
      else {
        throw MCPClientSessionError.protocolViolation
      }
      description = decoded
    } else {
      description = nil
    }
    let taskSupport = try decodeTaskSupport(from: object)
    return MCPRemoteTool(
      name: name,
      description: description,
      inputSchema: schema,
      taskSupport: taskSupport,
      supportsTaskAugmentedToolCalls: supportsTaskAugmentedToolCalls
    )
  }

  private static func decodeTaskSupport(
    from object: [String: JSONValue]
  ) throws -> MCPToolTaskSupport {
    guard let encodedExecution = object["execution"] else { return .forbidden }
    guard let execution = encodedExecution.mcpObject else {
      throw MCPClientSessionError.protocolViolation
    }
    guard let encodedTaskSupport = execution["taskSupport"] else { return .forbidden }
    guard
      let rawTaskSupport = encodedTaskSupport.mcpString,
      let taskSupport = MCPToolTaskSupport(rawValue: rawTaskSupport)
    else {
      throw MCPClientSessionError.protocolViolation
    }
    return taskSupport
  }
}
