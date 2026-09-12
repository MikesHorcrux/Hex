import Foundation
import HexCore

struct OpenAIResponsesContinuationMapper: Sendable {
  let configuration: OpenAIResponsesConfiguration
  private var validation: OpenAIResponsesInputValidator { .init(configuration: configuration) }
  private var inputEncoder: OpenAIResponsesInputEncoder { .init(configuration: configuration) }
  private var replayDecoder: OpenAIResponsesReplayDecoder { .init(configuration: configuration) }

  func mapServerContinuation(
    _ messages: [Message],
    state: OpenAIServerContinuationState
  ) throws -> [JSONValue] {
    do {
      try validateKnownHistory(
        messages,
        knownMessageIDs: state.knownMessageIDs,
        knownMessageFingerprints: state.knownMessageFingerprints
      )
      let tail = Array(messages.dropFirst(state.knownMessageIDs.count))
      let mirror = try assistantMirror(in: state.outputItems)
      if mirror.calls.isEmpty {
        guard
          tail.count == 2,
          tail[0].role == .assistant,
          tail[1].role == .user
        else {
          throw OpenAIResponsesProviderError.localContinuationMismatch
        }
        try validateAssistantMessage(tail[0], matches: mirror)
        var mapped: [JSONValue] = []
        try inputEncoder.append(tail[1], to: &mapped)
        guard
          !mapped.isEmpty,
          mapped.allSatisfy({ item in
            guard case .object(let object) = item else { return false }
            return object["type"] == .string("message")
          })
        else {
          throw OpenAIResponsesProviderError.localContinuationMismatch
        }
        return mapped
      }
      return try mapToolContinuation(tail, expectedMirror: mirror)
    } catch {
      throw OpenAIResponsesProviderError.invalidRequest
    }
  }

  func mapLocalReplay(
    _ messages: [Message],
    state: OpenAILocalContinuationState
  ) throws -> [JSONValue] {
    guard
      state.baseMessageCount <= state.knownMessageIDs.count,
      state.replaySegments.count <= configuration.maximumReplaySegments
    else {
      throw OpenAIResponsesProviderError.localContinuationMismatch
    }
    try validateKnownHistory(
      messages,
      knownMessageIDs: state.knownMessageIDs,
      knownMessageFingerprints: state.knownMessageFingerprints
    )

    var input = try inputEncoder.mapMessages(Array(messages.prefix(state.baseMessageCount)))
    var messageCursor = state.baseMessageCount
    var priorOutputItems: [JSONValue]?

    for segment in state.replaySegments {
      guard
        segment.afterMessageCount >= messageCursor,
        segment.afterMessageCount <= messages.count,
        segment.outputItems.count <= configuration.maximumOutputItems
      else {
        throw OpenAIResponsesProviderError.localContinuationMismatch
      }

      if segment.afterMessageCount > messageCursor {
        guard let priorOutputItems else {
          throw OpenAIResponsesProviderError.localContinuationMismatch
        }
        let expectedMirror = try assistantMirror(in: priorOutputItems)
        input.append(
          contentsOf: try mapToolContinuation(
            Array(messages[messageCursor..<segment.afterMessageCount]),
            expectedMirror: expectedMirror
          )
        )
      }

      input.append(contentsOf: try replayDecoder.mapLocalReplayOutputItems(segment.outputItems))
      priorOutputItems = segment.outputItems
      messageCursor = segment.afterMessageCount
    }

    guard let priorOutputItems else {
      throw OpenAIResponsesProviderError.localContinuationMismatch
    }
    let expectedMirror = try assistantMirror(in: priorOutputItems)
    input.append(
      contentsOf: try mapToolContinuation(
        Array(messages[messageCursor...]),
        expectedMirror: expectedMirror
      )
    )
    return input
  }

  func mapToolContinuation(
    _ messages: [Message],
    expectedMirror: OpenAIAssistantMirror
  ) throws -> [JSONValue] {
    guard
      messages.count >= 2,
      messages[0].role == .assistant,
      !expectedMirror.calls.isEmpty
    else {
      throw OpenAIResponsesProviderError.localContinuationMismatch
    }
    try validateAssistantMessage(messages[0], matches: expectedMirror)

    var expectedByID: [ToolCallID: ToolCall] = [:]
    for call in expectedMirror.calls {
      guard expectedByID.updateValue(call, forKey: call.id) == nil else {
        throw OpenAIResponsesProviderError.localContinuationMismatch
      }
    }

    var resultIDs = Set<ToolCallID>()
    var output: [JSONValue] = []
    for message in messages.dropFirst() {
      guard message.role == .tool, !message.content.isEmpty else {
        throw OpenAIResponsesProviderError.localContinuationMismatch
      }
      for content in message.content {
        guard case .toolResult(let result) = content else {
          throw OpenAIResponsesProviderError.localContinuationMismatch
        }
        guard
          expectedByID[result.toolCallID] != nil,
          resultIDs.insert(result.toolCallID).inserted
        else {
          throw OpenAIResponsesProviderError.localContinuationMismatch
        }
        output.append(try inputEncoder.mapToolResult(result))
      }
    }

    let expectedIDs = Set(expectedByID.keys)
    guard resultIDs == expectedIDs else {
      throw OpenAIResponsesProviderError.localContinuationMismatch
    }
    return output
  }

  func validateAssistantMessage(
    _ message: Message,
    matches expected: OpenAIAssistantMirror
  ) throws {
    guard message.role == .assistant, !message.content.isEmpty else {
      throw OpenAIResponsesProviderError.localContinuationMismatch
    }
    var text = ""
    var textByteCount = 0
    var calls: [ToolCall] = []
    for content in message.content {
      switch content {
      case .text(let value):
        let (newByteCount, overflowed) = textByteCount.addingReportingOverflow(
          value.utf8.count
        )
        guard !overflowed, newByteCount <= configuration.maximumInputValueBytes else {
          throw OpenAIResponsesProviderError.localContinuationMismatch
        }
        text.append(value)
        textByteCount = newByteCount
      case .toolCall(let call):
        try validation.validateToolCall(call)
        calls.append(call)
      case .image, .toolResult:
        throw OpenAIResponsesProviderError.localContinuationMismatch
      }
    }
    guard text == expected.text else {
      throw OpenAIResponsesProviderError.localContinuationMismatch
    }
    var actualByID: [ToolCallID: ToolCall] = [:]
    for call in calls {
      guard actualByID.updateValue(call, forKey: call.id) == nil else {
        throw OpenAIResponsesProviderError.localContinuationMismatch
      }
    }
    var expectedByID: [ToolCallID: ToolCall] = [:]
    for call in expected.calls {
      guard expectedByID.updateValue(call, forKey: call.id) == nil else {
        throw OpenAIResponsesProviderError.localContinuationMismatch
      }
    }
    guard actualByID == expectedByID else {
      throw OpenAIResponsesProviderError.localContinuationMismatch
    }
  }

  func assistantMirror(in outputItems: [JSONValue]) throws -> OpenAIAssistantMirror {
    var text = ""
    var textByteCount = 0
    var calls: [ToolCall] = []
    for item in outputItems {
      guard case .object(let object) = item else {
        throw OpenAIResponsesProviderError.localContinuationMismatch
      }
      let itemType: String
      guard case .string(let resolvedType)? = object["type"] else {
        throw OpenAIResponsesProviderError.localContinuationMismatch
      }
      itemType = resolvedType
      if itemType == "reasoning" {
        continue
      }
      if itemType == "message" {
        guard
          object["role"] == .string("assistant"),
          case .array(let content)? = object["content"]
        else {
          throw OpenAIResponsesProviderError.localContinuationMismatch
        }
        for value in content {
          guard
            case .object(let part) = value,
            case .string(let partType)? = part["type"]
          else {
            throw OpenAIResponsesProviderError.localContinuationMismatch
          }
          let valueKey: String
          switch partType {
          case "output_text":
            valueKey = "text"
          case "refusal":
            valueKey = "refusal"
          default:
            throw OpenAIResponsesProviderError.localContinuationMismatch
          }
          guard case .string(let value)? = part[valueKey] else {
            throw OpenAIResponsesProviderError.localContinuationMismatch
          }
          let (newByteCount, overflowed) = textByteCount.addingReportingOverflow(
            value.utf8.count
          )
          guard !overflowed, newByteCount <= configuration.maximumInputValueBytes else {
            throw OpenAIResponsesProviderError.localContinuationMismatch
          }
          text.append(value)
          textByteCount = newByteCount
        }
        continue
      }
      guard itemType == "function_call" else {
        throw OpenAIResponsesProviderError.localContinuationMismatch
      }
      guard
        case .string(let callID)? = object["call_id"],
        case .string(let name)? = object["name"],
        case .string(let arguments)? = object["arguments"]
      else {
        throw OpenAIResponsesProviderError.localContinuationMismatch
      }
      let argumentData = Data(arguments.utf8)
      guard argumentData.count <= configuration.maximumToolArgumentBytes else {
        throw OpenAIResponsesProviderError.localContinuationMismatch
      }
      let decoded: JSONValue
      do {
        try OpenAIJSONStructuralPreflight.validateObjectRoot(
          argumentData,
          maximumDepth: configuration.maximumJSONDepth,
          maximumNodes: configuration.maximumJSONNodes
        )
        decoded = try JSONDecoder().decode(JSONValue.self, from: argumentData)
      } catch {
        throw OpenAIResponsesProviderError.localContinuationMismatch
      }
      guard case .object(let argumentObject) = decoded else {
        throw OpenAIResponsesProviderError.localContinuationMismatch
      }
      let call = ToolCall(id: ToolCallID(rawValue: callID), name: name, arguments: argumentObject)
      try validation.validateToolCall(call)
      calls.append(call)
    }
    guard !text.isEmpty || !calls.isEmpty else {
      throw OpenAIResponsesProviderError.localContinuationMismatch
    }
    return OpenAIAssistantMirror(text: text, calls: calls)
  }

  func validateKnownHistory(
    _ messages: [Message],
    knownMessageIDs: [MessageID],
    knownMessageFingerprints: [OpenAIMessageFingerprint]
  ) throws {
    guard
      messages.count >= knownMessageIDs.count,
      knownMessageFingerprints.count == knownMessageIDs.count,
      Array(messages.prefix(knownMessageIDs.count).map(\.id)) == knownMessageIDs
    else {
      throw OpenAIResponsesProviderError.localContinuationMismatch
    }
    let fingerprints: [OpenAIMessageFingerprint]
    do {
      fingerprints = try messages.prefix(knownMessageIDs.count).map(
        OpenAIMessageFingerprint.make
      )
    } catch {
      throw OpenAIResponsesProviderError.localContinuationMismatch
    }
    guard fingerprints == knownMessageFingerprints else {
      throw OpenAIResponsesProviderError.localContinuationMismatch
    }
  }
}
