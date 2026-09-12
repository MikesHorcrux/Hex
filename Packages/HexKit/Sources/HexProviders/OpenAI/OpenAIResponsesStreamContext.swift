import HexCore

/// Immutable admission evidence shared with the channel accumulators for one event.
struct OpenAIResponsesStreamContext: Sendable {
  let lifecycle: OpenAIResponseLifecycle
  let addedOutputItems: [Int: JSONValue]
  let completedOutputItems: [Int: JSONValue]
  private let fields = OpenAIResponsesStreamFields()

  func requireStreaming() throws {
    guard lifecycle.isStreaming else {
      throw OpenAIResponsesProviderError.malformedStream
    }
  }

  func requireOutputItem(id: String, index: Int, type: String) throws {
    guard let value = addedOutputItems[index], case .object(let item) = value else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    guard
      try fields.requiredString("id", in: item) == id,
      try fields.requiredString("type", in: item) == type,
      completedOutputItems[index] == nil
    else {
      throw OpenAIResponsesProviderError.malformedStream
    }
  }
}
