import Foundation
import HexCore

struct OpenAIResponsesTextAccumulator: Sendable {
  let configuration: OpenAIResponsesConfiguration
  private let fields = OpenAIResponsesStreamFields()
  private var textParts: [OpenAITextPartKey: OpenAITextPartAssembly] = [:]
  private var textAnnotations: [OpenAITextPartKey: [Int: JSONValue]] = [:]

  var hasAssistantContent: Bool {
    textParts.contains {
      $0.key.channel == "message" && $0.value.partCompleted && $0.value.finalText?.isEmpty == false
    }
  }

  init(configuration: OpenAIResponsesConfiguration) { self.configuration = configuration }

  mutating func processContentPartAdded(
    _ object: [String: JSONValue], context: OpenAIResponsesStreamContext
  ) throws {
    try context.requireStreaming()
    let itemID = try fields.requiredString("item_id", in: object)
    let outputIndex = try fields.requiredIndex("output_index", in: object)
    let contentIndex = try fields.requiredIndex("content_index", in: object)
    guard contentIndex < configuration.maximumOutputItems else {
      throw OpenAIResponsesProviderError.streamLimitExceeded
    }
    try context.requireOutputItem(id: itemID, index: outputIndex, type: "message")
    let part = try fields.requiredObject("part", in: object)
    let partType = try fields.requiredString("type", in: part)
    guard partType == "output_text" || partType == "refusal" else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    let valueKey = partType == "output_text" ? "text" : "refusal"
    let initialText = try fields.requiredString(valueKey, in: part)
    let initialBytes = Data(initialText.utf8)
    guard initialBytes.count <= configuration.maximumSSEEventBytes else {
      throw OpenAIResponsesProviderError.streamLimitExceeded
    }
    let key = OpenAITextPartKey(channel: "message", itemID: itemID, index: contentIndex)
    let existingPartCount = textParts.keys.lazy.filter { key in
      key.channel == "message" && key.itemID == itemID
    }.count
    let previousPartCompleted =
      contentIndex == 0
      || textParts[
        OpenAITextPartKey(channel: "message", itemID: itemID, index: contentIndex - 1)
      ]?.partCompleted == true
    guard
      contentIndex == existingPartCount,
      previousPartCompleted,
      initialText.isEmpty,
      textParts[key] == nil
    else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    if partType == "output_text" {
      guard try fields.requiredArray("annotations", in: part).isEmpty else {
        throw OpenAIResponsesProviderError.malformedStream
      }
    }
    textParts[key] = OpenAITextPartAssembly(
      outputIndex: outputIndex,
      partType: partType,
      textBytes: initialBytes,
      finalText: nil,
      partCompleted: false
    )
  }

  mutating func processContentPartDone(
    _ object: [String: JSONValue], context: OpenAIResponsesStreamContext
  ) throws {
    try context.requireStreaming()
    let itemID = try fields.requiredString("item_id", in: object)
    let outputIndex = try fields.requiredIndex("output_index", in: object)
    let contentIndex = try fields.requiredIndex("content_index", in: object)
    try context.requireOutputItem(id: itemID, index: outputIndex, type: "message")
    let key = OpenAITextPartKey(channel: "message", itemID: itemID, index: contentIndex)
    guard var assembly = textParts[key], assembly.outputIndex == outputIndex else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    let part = try fields.requiredObject("part", in: object)
    let partType = try fields.requiredString("type", in: part)
    let valueKey = partType == "output_text" ? "text" : "refusal"
    guard
      partType == assembly.partType,
      let finalText = assembly.finalText,
      !assembly.partCompleted,
      try fields.requiredString(valueKey, in: part) == finalText
    else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    if partType == "output_text" {
      try validateAnnotations(in: part, for: key)
    }
    assembly.partCompleted = true
    textParts[key] = assembly
  }

  mutating func processTextDelta(
    _ object: [String: JSONValue], context: OpenAIResponsesStreamContext,
    partType: String
  ) throws -> OpenAIResponsesProcessedEvent {
    try context.requireStreaming()
    let itemID = try fields.requiredString("item_id", in: object)
    let outputIndex = try fields.requiredIndex("output_index", in: object)
    let contentIndex = try fields.requiredIndex("content_index", in: object)
    try context.requireOutputItem(id: itemID, index: outputIndex, type: "message")
    let delta = try fields.requiredString("delta", in: object)
    let key = OpenAITextPartKey(channel: "message", itemID: itemID, index: contentIndex)
    guard
      var assembly = textParts[key],
      assembly.outputIndex == outputIndex,
      assembly.partType == partType,
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
      events: delta.isEmpty ? [] : [.textDelta(delta)],
      terminalResult: nil
    )
  }

  mutating func processTextDone(
    _ object: [String: JSONValue], context: OpenAIResponsesStreamContext,
    partType: String,
    valueKey: String
  ) throws {
    try context.requireStreaming()
    let itemID = try fields.requiredString("item_id", in: object)
    let outputIndex = try fields.requiredIndex("output_index", in: object)
    let contentIndex = try fields.requiredIndex("content_index", in: object)
    try context.requireOutputItem(id: itemID, index: outputIndex, type: "message")
    let text = try fields.requiredString(valueKey, in: object)
    let key = OpenAITextPartKey(channel: "message", itemID: itemID, index: contentIndex)
    guard
      var assembly = textParts[key],
      assembly.outputIndex == outputIndex,
      assembly.partType == partType,
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

  mutating func processTextAnnotation(
    _ object: [String: JSONValue], context: OpenAIResponsesStreamContext
  ) throws {
    try context.requireStreaming()
    let itemID = try fields.requiredString("item_id", in: object)
    let outputIndex = try fields.requiredIndex("output_index", in: object)
    let contentIndex = try fields.requiredIndex("content_index", in: object)
    let annotationIndex = try fields.requiredIndex("annotation_index", in: object)
    guard annotationIndex < configuration.maximumOutputItems else {
      throw OpenAIResponsesProviderError.streamLimitExceeded
    }
    try context.requireOutputItem(id: itemID, index: outputIndex, type: "message")
    let key = OpenAITextPartKey(channel: "message", itemID: itemID, index: contentIndex)
    guard
      let assembly = textParts[key],
      assembly.outputIndex == outputIndex,
      assembly.partType == "output_text",
      assembly.finalText == nil,
      !assembly.partCompleted
    else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    let annotation = try fields.requiredValue("annotation", in: object)
    guard
      case .object(let annotationObject) = annotation,
      try fields.requiredString("type", in: annotationObject).utf8.count <= 128,
      OpenAIJSONValidator.measuredBytes(
        for: annotation,
        maximumDepth: configuration.maximumJSONDepth,
        maximumNodes: configuration.maximumJSONNodes,
        maximumStringBytes: configuration.maximumSSEEventBytes
      ) != nil
    else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    var annotations = textAnnotations[key] ?? [:]
    guard annotations[annotationIndex] == nil else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    annotations[annotationIndex] = annotation
    textAnnotations[key] = annotations
  }

  func validateCompletedMessage(
    _ item: [String: JSONValue],
    outputIndex: Int
  ) throws {
    let itemID = try fields.requiredString("id", in: item)
    guard try fields.requiredString("role", in: item) == "assistant" else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    let content = try fields.requiredArray("content", in: item)
    guard content.count <= configuration.maximumOutputItems else {
      throw OpenAIResponsesProviderError.streamLimitExceeded
    }
    let assemblyCount = textParts.keys.lazy.filter { key in
      key.channel == "message" && key.itemID == itemID
    }.count
    guard assemblyCount == content.count else {
      throw OpenAIResponsesProviderError.malformedStream
    }

    for (contentIndex, value) in content.enumerated() {
      guard case .object(let part) = value else {
        throw OpenAIResponsesProviderError.malformedStream
      }
      let key = OpenAITextPartKey(channel: "message", itemID: itemID, index: contentIndex)
      guard
        let assembly = textParts[key],
        assembly.outputIndex == outputIndex,
        assembly.partCompleted,
        let finalText = assembly.finalText,
        try fields.requiredString("type", in: part) == assembly.partType
      else {
        throw OpenAIResponsesProviderError.malformedStream
      }
      let valueKey = assembly.partType == "output_text" ? "text" : "refusal"
      guard try fields.requiredString(valueKey, in: part) == finalText else {
        throw OpenAIResponsesProviderError.malformedStream
      }
      if assembly.partType == "output_text" {
        try validateAnnotations(in: part, for: key)
      }
    }
  }

  func validateAnnotations(
    in part: [String: JSONValue],
    for key: OpenAITextPartKey
  ) throws {
    let completedAnnotations = try fields.requiredArray("annotations", in: part)
    let streamedAnnotations = textAnnotations[key] ?? [:]
    guard
      completedAnnotations.count <= configuration.maximumOutputItems,
      streamedAnnotations.count == completedAnnotations.count
    else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    for (annotationIndex, annotation) in completedAnnotations.enumerated() {
      guard streamedAnnotations[annotationIndex] == annotation else {
        throw OpenAIResponsesProviderError.malformedStream
      }
    }
  }
}
