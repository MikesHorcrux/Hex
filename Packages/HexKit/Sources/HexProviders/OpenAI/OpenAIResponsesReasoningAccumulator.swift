import Foundation
import HexCore

struct OpenAIResponsesReasoningAccumulator: Sendable {
  let configuration: OpenAIResponsesConfiguration
  private let fields = OpenAIResponsesStreamFields()
  private var textParts: [OpenAITextPartKey: OpenAITextPartAssembly] = [:]

  init(configuration: OpenAIResponsesConfiguration) { self.configuration = configuration }

  mutating func processReasoningPartAdded(
    _ object: [String: JSONValue], context: OpenAIResponsesStreamContext
  ) throws {
    try context.requireStreaming()
    let itemID = try fields.requiredString("item_id", in: object)
    let outputIndex = try fields.requiredIndex("output_index", in: object)
    let summaryIndex = try fields.requiredIndex("summary_index", in: object)
    guard summaryIndex < configuration.maximumOutputItems else {
      throw OpenAIResponsesProviderError.streamLimitExceeded
    }
    try context.requireOutputItem(id: itemID, index: outputIndex, type: "reasoning")
    let part = try fields.requiredObject("part", in: object)
    guard try fields.requiredString("type", in: part) == "summary_text" else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    let initialText = try fields.requiredString("text", in: part)
    let initialBytes = Data(initialText.utf8)
    guard initialBytes.count <= configuration.maximumSSEEventBytes else {
      throw OpenAIResponsesProviderError.streamLimitExceeded
    }
    let key = OpenAITextPartKey(
      channel: "reasoning_summary",
      itemID: itemID,
      index: summaryIndex
    )
    let existingPartCount = textParts.keys.lazy.filter { key in
      key.channel == "reasoning_summary" && key.itemID == itemID
    }.count
    let previousPartCompleted =
      summaryIndex == 0
      || textParts[
        OpenAITextPartKey(
          channel: "reasoning_summary",
          itemID: itemID,
          index: summaryIndex - 1
        )
      ]?.partCompleted == true
    guard
      summaryIndex == existingPartCount,
      previousPartCompleted,
      initialText.isEmpty,
      textParts[key] == nil
    else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    textParts[key] = OpenAITextPartAssembly(
      outputIndex: outputIndex,
      partType: "summary_text",
      textBytes: initialBytes,
      finalText: nil,
      partCompleted: false
    )
  }

  mutating func processReasoningPartDone(
    _ object: [String: JSONValue], context: OpenAIResponsesStreamContext
  ) throws {
    try context.requireStreaming()
    let itemID = try fields.requiredString("item_id", in: object)
    let outputIndex = try fields.requiredIndex("output_index", in: object)
    let summaryIndex = try fields.requiredIndex("summary_index", in: object)
    try context.requireOutputItem(id: itemID, index: outputIndex, type: "reasoning")
    let key = OpenAITextPartKey(
      channel: "reasoning_summary",
      itemID: itemID,
      index: summaryIndex
    )
    guard var assembly = textParts[key], assembly.outputIndex == outputIndex else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    let part = try fields.requiredObject("part", in: object)
    guard
      try fields.requiredString("type", in: part) == assembly.partType,
      let finalText = assembly.finalText,
      !assembly.partCompleted,
      try fields.requiredString("text", in: part) == finalText
    else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    assembly.partCompleted = true
    textParts[key] = assembly
  }

  mutating func processReasoningSummaryDelta(
    _ object: [String: JSONValue], context: OpenAIResponsesStreamContext
  ) throws -> OpenAIResponsesProcessedEvent {
    try context.requireStreaming()
    let itemID = try fields.requiredString("item_id", in: object)
    let outputIndex = try fields.requiredIndex("output_index", in: object)
    let summaryIndex = try fields.requiredIndex("summary_index", in: object)
    try context.requireOutputItem(id: itemID, index: outputIndex, type: "reasoning")
    let delta = try fields.requiredString("delta", in: object)
    let key = OpenAITextPartKey(
      channel: "reasoning_summary",
      itemID: itemID,
      index: summaryIndex
    )
    guard
      var assembly = textParts[key],
      assembly.outputIndex == outputIndex,
      assembly.partType == "summary_text",
      assembly.finalText == nil,
      !assembly.partCompleted
    else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    let deltaBytes = Data(delta.utf8)
    let (newCount, overflowed) = assembly.textBytes.count.addingReportingOverflow(
      deltaBytes.count
    )
    guard !overflowed, newCount <= configuration.maximumSSEEventBytes else {
      throw OpenAIResponsesProviderError.streamLimitExceeded
    }
    assembly.textBytes.append(deltaBytes)
    textParts[key] = assembly
    return OpenAIResponsesProcessedEvent(
      events: delta.isEmpty ? [] : [.reasoningSummaryDelta(delta)],
      terminalResult: nil
    )
  }

  mutating func processReasoningSummaryDone(
    _ object: [String: JSONValue], context: OpenAIResponsesStreamContext
  ) throws {
    try context.requireStreaming()
    let itemID = try fields.requiredString("item_id", in: object)
    let outputIndex = try fields.requiredIndex("output_index", in: object)
    let summaryIndex = try fields.requiredIndex("summary_index", in: object)
    try context.requireOutputItem(id: itemID, index: outputIndex, type: "reasoning")
    let text = try fields.requiredString("text", in: object)
    let key = OpenAITextPartKey(
      channel: "reasoning_summary",
      itemID: itemID,
      index: summaryIndex
    )
    guard
      var assembly = textParts[key],
      assembly.outputIndex == outputIndex,
      assembly.partType == "summary_text",
      assembly.finalText == nil,
      !assembly.partCompleted,
      assembly.textBytes == Data(text.utf8)
    else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    guard text.utf8.count <= configuration.maximumSSEEventBytes else {
      throw OpenAIResponsesProviderError.streamLimitExceeded
    }
    assembly.finalText = text
    textParts[key] = assembly
  }

  mutating func processReasoningTextDelta(
    _ object: [String: JSONValue], context: OpenAIResponsesStreamContext
  ) throws {
    try context.requireStreaming()
    let itemID = try fields.requiredString("item_id", in: object)
    let outputIndex = try fields.requiredIndex("output_index", in: object)
    let contentIndex = try fields.requiredIndex("content_index", in: object)
    guard contentIndex < configuration.maximumOutputItems else {
      throw OpenAIResponsesProviderError.streamLimitExceeded
    }
    try context.requireOutputItem(id: itemID, index: outputIndex, type: "reasoning")
    let delta = try fields.requiredString("delta", in: object)
    let key = OpenAITextPartKey(
      channel: "reasoning_text",
      itemID: itemID,
      index: contentIndex
    )
    var assembly: OpenAITextPartAssembly
    if let existing = textParts[key] {
      assembly = existing
    } else {
      let existingPartCount = textParts.keys.lazy.filter { key in
        key.channel == "reasoning_text" && key.itemID == itemID
      }.count
      let previousPartCompleted =
        contentIndex == 0
        || textParts[
          OpenAITextPartKey(
            channel: "reasoning_text",
            itemID: itemID,
            index: contentIndex - 1
          )
        ]?.partCompleted == true
      guard contentIndex == existingPartCount, previousPartCompleted else {
        throw OpenAIResponsesProviderError.malformedStream
      }
      assembly = OpenAITextPartAssembly(
        outputIndex: outputIndex,
        partType: "reasoning_text",
        textBytes: Data(),
        finalText: nil,
        partCompleted: false
      )
    }
    guard
      assembly.outputIndex == outputIndex,
      assembly.finalText == nil,
      !assembly.partCompleted
    else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    let deltaBytes = Data(delta.utf8)
    let (newCount, overflowed) = assembly.textBytes.count.addingReportingOverflow(
      deltaBytes.count
    )
    guard !overflowed, newCount <= configuration.maximumSSEEventBytes else {
      throw OpenAIResponsesProviderError.streamLimitExceeded
    }
    assembly.textBytes.append(deltaBytes)
    textParts[key] = assembly
  }

  mutating func processReasoningTextDone(
    _ object: [String: JSONValue], context: OpenAIResponsesStreamContext
  ) throws {
    try context.requireStreaming()
    let itemID = try fields.requiredString("item_id", in: object)
    let outputIndex = try fields.requiredIndex("output_index", in: object)
    let contentIndex = try fields.requiredIndex("content_index", in: object)
    try context.requireOutputItem(id: itemID, index: outputIndex, type: "reasoning")
    let text = try fields.requiredString("text", in: object)
    let key = OpenAITextPartKey(
      channel: "reasoning_text",
      itemID: itemID,
      index: contentIndex
    )
    guard
      var assembly = textParts[key],
      assembly.outputIndex == outputIndex,
      assembly.finalText == nil,
      !assembly.partCompleted,
      assembly.textBytes == Data(text.utf8)
    else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    guard text.utf8.count <= configuration.maximumSSEEventBytes else {
      throw OpenAIResponsesProviderError.streamLimitExceeded
    }
    assembly.finalText = text
    assembly.partCompleted = true
    textParts[key] = assembly
  }

  func validateCompletedReasoning(
    _ item: [String: JSONValue],
    outputIndex: Int
  ) throws {
    let itemID = try fields.requiredString("id", in: item)
    let summary = try fields.requiredArray("summary", in: item)
    guard summary.count <= configuration.maximumOutputItems else {
      throw OpenAIResponsesProviderError.streamLimitExceeded
    }
    let assemblyCount = textParts.keys.lazy.filter { key in
      key.channel == "reasoning_summary" && key.itemID == itemID
    }.count
    guard assemblyCount == summary.count else {
      throw OpenAIResponsesProviderError.malformedStream
    }

    for (summaryIndex, value) in summary.enumerated() {
      guard case .object(let part) = value else {
        throw OpenAIResponsesProviderError.malformedStream
      }
      let key = OpenAITextPartKey(
        channel: "reasoning_summary",
        itemID: itemID,
        index: summaryIndex
      )
      guard
        let assembly = textParts[key],
        assembly.outputIndex == outputIndex,
        assembly.partType == "summary_text",
        assembly.partCompleted,
        let finalText = assembly.finalText,
        try fields.requiredString("type", in: part) == "summary_text",
        try fields.requiredString("text", in: part) == finalText
      else {
        throw OpenAIResponsesProviderError.malformedStream
      }
    }

    let content = try fields.optionalArray("content", in: item) ?? []
    guard content.count <= configuration.maximumOutputItems else {
      throw OpenAIResponsesProviderError.streamLimitExceeded
    }
    let reasoningTextCount = textParts.keys.lazy.filter { key in
      key.channel == "reasoning_text" && key.itemID == itemID
    }.count
    guard reasoningTextCount == content.count else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    for (contentIndex, value) in content.enumerated() {
      guard case .object(let part) = value else {
        throw OpenAIResponsesProviderError.malformedStream
      }
      let key = OpenAITextPartKey(
        channel: "reasoning_text",
        itemID: itemID,
        index: contentIndex
      )
      guard
        let assembly = textParts[key],
        assembly.outputIndex == outputIndex,
        assembly.partType == "reasoning_text",
        assembly.partCompleted,
        let finalText = assembly.finalText,
        try fields.requiredString("type", in: part) == "reasoning_text",
        try fields.requiredString("text", in: part) == finalText
      else {
        throw OpenAIResponsesProviderError.malformedStream
      }
    }
  }
}
