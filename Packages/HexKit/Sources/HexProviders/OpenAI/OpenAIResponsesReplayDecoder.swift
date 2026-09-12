import Foundation
import HexCore

struct OpenAIResponsesReplayDecoder: Sendable {
  let configuration: OpenAIResponsesConfiguration
  private var validation: OpenAIResponsesInputValidator { .init(configuration: configuration) }

  func mapLocalReplayOutputItems(
    _ outputItems: [JSONValue]
  ) throws -> [JSONValue] {
    try outputItems.map { value in
      guard
        case .object(let item) = value,
        case .string(let itemType)? = item["type"]
      else {
        throw OpenAIResponsesProviderError.localContinuationMismatch
      }

      switch itemType {
      case "reasoning":
        guard
          case .string(let encryptedContent)? = item["encrypted_content"],
          !encryptedContent.isEmpty,
          encryptedContent.utf8.count <= configuration.maximumLocalStateBytes,
          case .array(let summary)? = item["summary"],
          summary.count <= configuration.maximumOutputItems
        else {
          throw OpenAIResponsesProviderError.localContinuationMismatch
        }
        let mappedSummary = try mapLocalReplayReasoningSummary(summary)
        let mapped = JSONValue.object([
          "type": .string("reasoning"),
          "encrypted_content": .string(encryptedContent),
          "summary": .array(mappedSummary),
        ])
        guard
          OpenAIJSONValidator.measuredBytes(
            for: mapped,
            maximumDepth: configuration.maximumJSONDepth,
            maximumNodes: configuration.maximumJSONNodes,
            maximumStringBytes: configuration.maximumLocalStateBytes
          ) != nil
        else {
          throw OpenAIResponsesProviderError.localContinuationMismatch
        }
        return mapped

      case "function_call":
        guard
          case .string(let callID)? = item["call_id"],
          case .string(let name)? = item["name"],
          case .string(let arguments)? = item["arguments"]
        else {
          throw OpenAIResponsesProviderError.localContinuationMismatch
        }
        let call = ToolCall(
          id: ToolCallID(rawValue: callID),
          name: name,
          arguments: try decodeReplayArguments(arguments)
        )
        try validation.validateToolCall(call)
        return .object([
          "type": .string("function_call"),
          "call_id": .string(callID),
          "name": .string(name),
          "arguments": .string(arguments),
        ])

      case "message":
        guard
          item["role"] == .string("assistant"),
          case .string(let status)? = item["status"],
          status == "completed" || status == "incomplete",
          case .array(let content)? = item["content"],
          content.count <= configuration.maximumOutputItems
        else {
          throw OpenAIResponsesProviderError.localContinuationMismatch
        }
        let mappedContent = try mapLocalReplayMessageContent(content)
        var mapped: [String: JSONValue] = [
          "type": .string("message"),
          "role": .string("assistant"),
          "status": .string(status),
          "content": .array(mappedContent),
        ]
        if case .string(let phase)? = item["phase"],
          phase == "commentary" || phase == "final_answer"
        {
          mapped["phase"] = .string(phase)
        }
        let mappedValue = JSONValue.object(mapped)
        guard
          OpenAIJSONValidator.measuredBytes(
            for: mappedValue,
            maximumDepth: configuration.maximumJSONDepth,
            maximumNodes: configuration.maximumJSONNodes,
            maximumStringBytes: configuration.maximumInputValueBytes
          ) != nil
        else {
          throw OpenAIResponsesProviderError.localContinuationMismatch
        }
        return mappedValue

      default:
        throw OpenAIResponsesProviderError.localContinuationMismatch
      }
    }
  }

  func mapLocalReplayReasoningSummary(
    _ summary: [JSONValue]
  ) throws -> [JSONValue] {
    try summary.map { value in
      guard
        case .object(let part) = value,
        part["type"] == .string("summary_text"),
        case .string(let text)? = part["text"],
        text.utf8.count <= configuration.maximumInputValueBytes
      else {
        throw OpenAIResponsesProviderError.localContinuationMismatch
      }
      return .object([
        "type": .string("summary_text"),
        "text": .string(text),
      ])
    }
  }

  func mapLocalReplayMessageContent(
    _ content: [JSONValue]
  ) throws -> [JSONValue] {
    try content.map { value in
      guard
        case .object(let part) = value,
        case .string(let partType)? = part["type"]
      else {
        throw OpenAIResponsesProviderError.localContinuationMismatch
      }

      switch partType {
      case "output_text":
        guard
          case .string(let text)? = part["text"],
          text.utf8.count <= configuration.maximumInputValueBytes,
          case .array(let annotations)? = part["annotations"],
          annotations.count <= configuration.maximumOutputItems
        else {
          throw OpenAIResponsesProviderError.localContinuationMismatch
        }
        return .object([
          "type": .string("output_text"),
          "text": .string(text),
          // Provider annotation identifiers are response-scoped and cannot be replayed safely.
          "annotations": .array([]),
        ])

      case "refusal":
        guard
          case .string(let refusal)? = part["refusal"],
          refusal.utf8.count <= configuration.maximumInputValueBytes
        else {
          throw OpenAIResponsesProviderError.localContinuationMismatch
        }
        return .object([
          "type": .string("refusal"),
          "refusal": .string(refusal),
        ])

      default:
        throw OpenAIResponsesProviderError.localContinuationMismatch
      }
    }
  }

  func decodeReplayArguments(_ arguments: String) throws -> [String: JSONValue] {
    let data = Data(arguments.utf8)
    guard data.count <= configuration.maximumToolArgumentBytes else {
      throw OpenAIResponsesProviderError.localContinuationMismatch
    }
    do {
      try OpenAIJSONStructuralPreflight.validateObjectRoot(
        data,
        maximumDepth: configuration.maximumJSONDepth,
        maximumNodes: configuration.maximumJSONNodes
      )
      let value = try JSONDecoder().decode(JSONValue.self, from: data)
      guard case .object(let object) = value else {
        throw OpenAIResponsesProviderError.localContinuationMismatch
      }
      return object
    } catch {
      throw OpenAIResponsesProviderError.localContinuationMismatch
    }
  }
}
