import Foundation
import HexCore

enum MCPToolResultMapper {
  static func map(
    _ remoteResult: MCPRemoteToolResult,
    call: ToolCall,
    route: MCPToolRoute
  ) throws -> ToolResult {
    guard remoteResult.content.count <= 1_024 else {
      throw MCPToolExecutorError.invalidToolResult
    }
    var remainingContentBytes = 2 * 1_024 * 1_024
    if let structuredContent = remoteResult.structuredContent {
      guard
        structuredContent.mcpObject != nil,
        MCPJSONValueValidator.isValid(
          structuredContent,
          maximumStringBytes: 1 * 1_024 * 1_024,
          maximumEstimatedBytes: 1 * 1_024 * 1_024
        ),
        let encodedStructuredContent = try? JSONEncoder().encode(structuredContent),
        consume(
          byteCounts: [encodedStructuredContent.count],
          overhead: 64,
          from: &remainingContentBytes
        )
      else {
        throw MCPToolExecutorError.invalidToolResult
      }
    }
    var resultContent: [ToolResultContent] = []
    var encodedContent: [JSONValue] = []
    resultContent.reserveCapacity(remoteResult.content.count)
    encodedContent.reserveCapacity(remoteResult.content.count)

    for item in remoteResult.content {
      switch item {
      case .text(let text):
        guard
          text.utf8.count <= 1 * 1_024 * 1_024,
          !text.contains("\0"),
          consume(byteCounts: [text.utf8.count], overhead: 64, from: &remainingContentBytes)
        else {
          throw MCPToolExecutorError.invalidToolResult
        }
        resultContent.append(.text(text))
        encodedContent.append(.object(["type": .string("text"), "text": .string(text)]))
      case .image(let data, let mimeType):
        guard
          data.utf8.count <= 2 * 1_024 * 1_024,
          isValidMediaType(mimeType, prefix: "image/"),
          consume(
            byteCounts: [data.utf8.count, mimeType.utf8.count],
            overhead: 64,
            from: &remainingContentBytes
          ),
          Data(base64Encoded: data, options: []).map({ $0.base64EncodedString() }) == data,
          let url = URL(string: "data:\(mimeType);base64,\(data)")
        else {
          throw MCPToolExecutorError.invalidToolResult
        }
        resultContent.append(.image(ImageContent(sourceURL: url, mediaType: mimeType)))
        encodedContent.append(
          .object([
            "type": .string("image"),
            "data": .string(data),
            "mimeType": .string(mimeType),
          ])
        )
      case .audio(let data, let mimeType):
        guard
          data.utf8.count <= 2 * 1_024 * 1_024,
          isValidMediaType(mimeType, prefix: "audio/"),
          consume(
            byteCounts: [data.utf8.count, mimeType.utf8.count],
            overhead: 64,
            from: &remainingContentBytes
          ),
          Data(base64Encoded: data, options: []).map({ $0.base64EncodedString() }) == data
        else {
          throw MCPToolExecutorError.invalidToolResult
        }
        encodedContent.append(
          .object([
            "type": .string("audio"),
            "data": .string(data),
            "mimeType": .string(mimeType),
          ])
        )
      case .resourceLink(let resource):
        guard
          !resource.name.isEmpty,
          resource.name.utf8.count <= 512,
          !resource.name.contains("\0"),
          !resource.uri.isEmpty,
          resource.uri.utf8.count <= 8_192,
          !resource.uri.contains("\0"),
          (resource.title?.utf8.count ?? 0) <= 512,
          (resource.description?.utf8.count ?? 0) <= 4_096,
          (resource.mimeType?.utf8.count ?? 0) <= 128,
          resource.title.map({ !$0.contains("\0") }) ?? true,
          resource.description.map({ !$0.contains("\0") }) ?? true,
          resource.mimeType.map({ !$0.contains("\0") }) ?? true,
          resource.size.map({ $0 >= 0 }) ?? true,
          consume(
            byteCounts: [
              resource.name.utf8.count,
              resource.title?.utf8.count ?? 0,
              resource.uri.utf8.count,
              resource.description?.utf8.count ?? 0,
              resource.mimeType?.utf8.count ?? 0,
            ],
            overhead: 128,
            from: &remainingContentBytes
          )
        else {
          throw MCPToolExecutorError.invalidToolResult
        }
        var value: [String: JSONValue] = [
          "type": .string("resource_link"),
          "name": .string(resource.name),
          "uri": .string(resource.uri),
        ]
        if let title = resource.title { value["title"] = .string(title) }
        if let description = resource.description {
          value["description"] = .string(description)
        }
        if let mimeType = resource.mimeType { value["mimeType"] = .string(mimeType) }
        if let size = resource.size { value["size"] = .integer(size) }
        encodedContent.append(.object(value))
        resultContent.append(.text("[resource link \(resource.name)] \(resource.uri)"))
      case .resource(let resource):
        guard
          !resource.uri.isEmpty,
          resource.uri.utf8.count <= 8_192,
          !resource.uri.contains("\0"),
          (resource.mimeType?.utf8.count ?? 0) <= 128,
          (resource.text?.utf8.count ?? 0) <= 1 * 1_024 * 1_024,
          (resource.blob?.utf8.count ?? 0) <= 2 * 1_024 * 1_024,
          resource.mimeType.map({ !$0.contains("\0") }) ?? true,
          resource.text.map({ !$0.contains("\0") }) ?? true,
          (resource.text == nil) != (resource.blob == nil),
          consume(
            byteCounts: [
              resource.uri.utf8.count,
              resource.mimeType?.utf8.count ?? 0,
              resource.text?.utf8.count ?? 0,
              resource.blob?.utf8.count ?? 0,
            ],
            overhead: 128,
            from: &remainingContentBytes
          )
        else {
          throw MCPToolExecutorError.invalidToolResult
        }
        var value: [String: JSONValue] = [
          "type": .string("resource"),
          "uri": .string(resource.uri),
        ]
        if let mimeType = resource.mimeType {
          value["mimeType"] = .string(mimeType)
        }
        if let text = resource.text {
          value["text"] = .string(text)
          resultContent.append(.text("[resource \(resource.uri)]\n\(text)"))
        }
        if let blob = resource.blob {
          guard Data(base64Encoded: blob, options: [])?.base64EncodedString() == blob else {
            throw MCPToolExecutorError.invalidToolResult
          }
          value["blob"] = .string(blob)
        }
        encodedContent.append(.object(value))
      }
    }

    var output: [String: JSONValue] = [
      "server": .string(route.serverID),
      "tool": .string(route.remoteName),
      "isError": .boolean(remoteResult.isError),
      "content": .array(encodedContent),
    ]
    if let structuredContent = remoteResult.structuredContent {
      output["structuredContent"] = structuredContent
    }
    let outputValue = JSONValue.object(output)
    guard
      MCPJSONValueValidator.isValid(
        outputValue,
        maximumStringBytes: 2 * 1_024 * 1_024,
        maximumEstimatedBytes: 2 * 1_024 * 1_024
      ),
      let encoded = try? JSONEncoder().encode(outputValue),
      encoded.count <= 2 * 1_024 * 1_024
    else {
      throw MCPToolExecutorError.invalidToolResult
    }

    return ToolResult(
      toolCallID: call.id,
      status: remoteResult.isError ? .failure : .success,
      output: outputValue,
      content: resultContent
    )
  }

  private static func isValidMediaType(_ value: String, prefix: String) -> Bool {
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

  private static func consume(
    byteCounts: [Int],
    overhead: Int,
    from remaining: inout Int
  ) -> Bool {
    var required = overhead
    for count in byteCounts {
      let (next, overflowed) = required.addingReportingOverflow(count)
      guard !overflowed else { return false }
      required = next
    }
    guard required <= remaining else { return false }
    remaining -= required
    return true
  }
}
