import Foundation
import HexCore

enum MCPRemoteToolResultDecoder {
  static func decode(
    _ value: JSONValue,
    maximumContentItems: Int
  ) throws -> MCPRemoteToolResult {
    guard
      let object = value.mcpObject,
      let encodedContent = object["content"]?.mcpArray,
      encodedContent.count <= maximumContentItems
    else {
      throw MCPClientSessionError.protocolViolation
    }
    let isError: Bool
    if let encodedIsError = object["isError"] {
      guard let decoded = encodedIsError.mcpBoolean else {
        throw MCPClientSessionError.protocolViolation
      }
      isError = decoded
    } else {
      isError = false
    }
    let structuredContent: JSONValue?
    if let encodedStructuredContent = object["structuredContent"] {
      guard encodedStructuredContent.mcpObject != nil else {
        throw MCPClientSessionError.protocolViolation
      }
      structuredContent = encodedStructuredContent
    } else {
      structuredContent = nil
    }
    let content = try encodedContent.map(decodeContent)
    return MCPRemoteToolResult(
      content: content,
      structuredContent: structuredContent,
      isError: isError
    )
  }

  private static func decodeContent(_ value: JSONValue) throws -> MCPToolContent {
    guard
      let object = value.mcpObject,
      let type = object["type"]?.mcpString
    else {
      throw MCPClientSessionError.protocolViolation
    }
    switch type {
    case "text":
      guard
        let text = object["text"]?.mcpString,
        text.utf8.count <= 2 * 1_024 * 1_024,
        !text.contains("\0")
      else {
        throw MCPClientSessionError.protocolViolation
      }
      return .text(text)
    case "image":
      return try decodeBinary(object, expectedPrefix: "image/", make: MCPToolContent.image)
    case "audio":
      return try decodeBinary(object, expectedPrefix: "audio/", make: MCPToolContent.audio)
    case "resource_link":
      return .resourceLink(try decodeResourceLink(object))
    case "resource":
      return .resource(try decodeResource(object))
    default:
      throw MCPClientSessionError.protocolViolation
    }
  }

  private static func decodeResourceLink(
    _ object: [String: JSONValue]
  ) throws -> MCPResourceLink {
    guard
      let name = object["name"]?.mcpString,
      !name.isEmpty,
      name.utf8.count <= 512,
      !name.contains("\0"),
      let uri = object["uri"]?.mcpString,
      !uri.isEmpty,
      uri.utf8.count <= 8_192,
      !uri.contains("\0")
    else {
      throw MCPClientSessionError.protocolViolation
    }
    let title = try optionalString(object["title"], maximumBytes: 512)
    let description = try optionalString(object["description"], maximumBytes: 4_096)
    let mimeType = try optionalString(object["mimeType"], maximumBytes: 128)
    let size: Int64?
    if let encodedSize = object["size"] {
      guard let decodedSize = encodedSize.mcpInteger, decodedSize >= 0 else {
        throw MCPClientSessionError.protocolViolation
      }
      size = decodedSize
    } else {
      size = nil
    }
    return MCPResourceLink(
      name: name,
      title: title,
      uri: uri,
      description: description,
      mimeType: mimeType,
      size: size
    )
  }

  private static func decodeBinary(
    _ object: [String: JSONValue],
    expectedPrefix: String,
    make: (String, String) -> MCPToolContent
  ) throws -> MCPToolContent {
    guard
      let data = object["data"]?.mcpString,
      let mimeType = object["mimeType"]?.mcpString,
      validMediaType(mimeType, prefix: expectedPrefix),
      Data(base64Encoded: data, options: [])?.base64EncodedString() == data
    else {
      throw MCPClientSessionError.protocolViolation
    }
    return make(data, mimeType)
  }

  private static func decodeResource(
    _ object: [String: JSONValue]
  ) throws -> MCPEmbeddedResource {
    guard
      let resource = object["resource"]?.mcpObject,
      let uri = resource["uri"]?.mcpString,
      !uri.isEmpty,
      uri.utf8.count <= 8_192,
      !uri.contains("\0")
    else {
      throw MCPClientSessionError.protocolViolation
    }
    let mimeType = try optionalString(resource["mimeType"], maximumBytes: 128)
    let text = try optionalString(resource["text"], maximumBytes: 2 * 1_024 * 1_024)
    let blob = try optionalString(resource["blob"], maximumBytes: 2 * 1_024 * 1_024)
    guard (text == nil) != (blob == nil) else {
      throw MCPClientSessionError.protocolViolation
    }
    if let blob, Data(base64Encoded: blob, options: [])?.base64EncodedString() != blob {
      throw MCPClientSessionError.protocolViolation
    }
    return MCPEmbeddedResource(
      uri: uri,
      mimeType: mimeType,
      text: text,
      blob: blob
    )
  }

  private static func optionalString(
    _ value: JSONValue?,
    maximumBytes: Int
  ) throws -> String? {
    guard let value else { return nil }
    guard
      let string = value.mcpString,
      string.utf8.count <= maximumBytes,
      !string.contains("\0")
    else {
      throw MCPClientSessionError.protocolViolation
    }
    return string
  }

  private static func validMediaType(_ value: String, prefix: String) -> Bool {
    value.hasPrefix(prefix)
      && value.utf8.count <= 128
      && value.utf8.allSatisfy { byte in
        (48...57).contains(byte)
          || (65...90).contains(byte)
          || (97...122).contains(byte)
          || byte == 43
          || byte == 45
          || byte == 46
          || byte == 47
      }
  }
}
