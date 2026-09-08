import Foundation
import HexCore

/// Storage limits are provider-neutral. Adapters still validate model-specific image and tool
/// support before inference; this validator never resolves a stored URL or executes a tool.
nonisolated enum AgentConversationPayloadValidator {
  static let maximumPayloadBytes = 1_024 * 1_024
  static let maximumContentParts = 256
  private static let maximumJSONDepth = 32
  private static let maximumJSONNodes = 65_536

  static func validate(_ message: Message) throws {
    guard !message.content.isEmpty, message.content.count <= maximumContentParts else {
      throw invalid("A native message has an empty or oversized content list.")
    }
    for content in message.content {
      switch content {
      case .text(let text):
        guard message.role == .user || message.role == .assistant else {
          throw invalid("Text is attached to an incompatible native message role.")
        }
        try validateText(text, maximumBytes: AgentConversation.maximumPersistedTextBytes)
      case .image(let image):
        guard message.role == .user else {
          throw invalid("An image is attached to an incompatible native message role.")
        }
        try validateImage(image)
      case .toolCall(let call):
        guard message.role == .assistant else {
          throw invalid("A tool call is attached to an incompatible native message role.")
        }
        try validateIdentifier(call.id.rawValue, maximumBytes: 512)
        try validateIdentifier(call.name, maximumBytes: 128)
        try validateJSON(.object(call.arguments))
        try validateEncodedPayload(call)
      case .toolResult(let result):
        guard message.role == .tool, result.content.count <= maximumContentParts,
          result.hasValidNonExecutionMetadata
        else {
          throw invalid("A tool result has an incompatible role or oversized content list.")
        }
        try validateIdentifier(result.toolCallID.rawValue, maximumBytes: 512)
        do { try ToolArtifactValidation.validate(result.artifacts) } catch {
          throw invalid("A native tool result contains invalid output references.")
        }
        try validateJSON(result.output)
        for part in result.content {
          switch part {
          case .text(let text):
            try validateText(text, maximumBytes: maximumPayloadBytes)
          case .image(let image):
            try validateImage(image)
          }
        }
        try validateEncodedPayload(result)
      }
    }
  }

  private static func validateText(_ text: String, maximumBytes: Int) throws {
    guard !text.isEmpty, text.utf8.count <= maximumBytes else {
      throw invalid("A native text payload is empty or oversized.")
    }
  }

  private static func validateIdentifier(_ value: String, maximumBytes: Int) throws {
    guard !value.isEmpty, value.utf8.count <= maximumBytes,
      value.utf8.allSatisfy({ (0x21...0x7E).contains($0) })
    else { throw invalid("A native tool identifier is invalid.") }
  }

  private static func validateJSON(_ value: JSONValue) throws {
    var pending = [(value: value, depth: 0)]
    var visited = 0
    while let item = pending.popLast() {
      visited += 1
      guard visited <= maximumJSONNodes, item.depth <= maximumJSONDepth else {
        throw invalid("A native JSON payload exceeds structural limits.")
      }
      switch item.value {
      case .null, .boolean, .integer:
        break
      case .number(let number):
        guard number.isFinite, Int64(exactly: number) == nil else {
          throw invalid("A native JSON number is not canonical.")
        }
      case .string(let string):
        guard string.utf8.count <= maximumPayloadBytes else {
          throw invalid("A native JSON string is oversized.")
        }
      case .array(let values):
        guard values.count <= maximumJSONNodes - visited - pending.count else {
          throw invalid("A native JSON payload exceeds structural limits.")
        }
        pending.append(contentsOf: values.map { ($0, item.depth + 1) })
      case .object(let values):
        guard values.count <= maximumJSONNodes - visited - pending.count,
          values.keys.allSatisfy({ $0.utf8.count <= 4_096 })
        else { throw invalid("A native JSON object exceeds structural limits.") }
        pending.append(contentsOf: values.values.map { ($0, item.depth + 1) })
      }
    }
    try validateEncodedPayload(value)
  }

  private static func validateImage(_ image: ImageContent) throws {
    let type = image.mediaType
    let source = image.sourceURL
    guard type.hasPrefix("image/"), type.count > 6, type.utf8.count <= 128,
      type.utf8.allSatisfy({ byte in
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
          || [43, 45, 46, 47].contains(byte)
      }),
      source.absoluteString.utf8.count <= maximumPayloadBytes,
      !source.absoluteString.contains("\0"), source.user == nil, source.password == nil,
      let scheme = source.scheme?.lowercased()
    else { throw invalid("A native image reference is invalid or oversized.") }
    switch scheme {
    case "https", "http":
      guard let host = source.host, !host.isEmpty, source.absoluteString.utf8.count <= 8_192 else {
        throw invalid("A native image URL is invalid.")
      }
    case "file":
      guard source.isFileURL, source.path.hasPrefix("/"), source.path.utf8.count <= 4_096 else {
        throw invalid("A native image file reference is invalid.")
      }
    case "data":
      let prefix = "data:\(type);base64,"
      let absolute = source.absoluteString
      guard absolute.hasPrefix(prefix) else { throw invalid("A native image data URL is invalid.") }
      let base64 = String(absolute.dropFirst(prefix.count))
      guard !base64.isEmpty, let decoded = Data(base64Encoded: base64),
        decoded.base64EncodedString() == base64
      else { throw invalid("A native image payload is not canonical base64.") }
    default:
      throw invalid("A native image URL scheme is unsupported.")
    }
  }

  private static func validateEncodedPayload<T: Encodable>(_ value: T) throws {
    let data: Data
    do { data = try JSONEncoder().encode(value) } catch {
      throw invalid("A native payload cannot be encoded canonically.")
    }
    guard data.count <= maximumPayloadBytes else {
      throw invalid("A native payload exceeds the saved-history byte limit.")
    }
  }

  private static func invalid(_ reason: String) -> AgentConversationStoreError {
    .invalidArchive(reason)
  }
}
