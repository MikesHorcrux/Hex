import Foundation
import HexCore

struct OpenAIResponsesStreamProcessor {
  private let configuration: OpenAIResponsesConfiguration
  private var lifecycle = OpenAIResponseLifecycle.awaitingStart
  private var responseID: String?
  private var lastSequenceNumber: Int64?
  private var addedOutputItems: [Int: JSONValue] = [:]
  private var completedOutputItems: [Int: JSONValue] = [:]
  private var outputItemIDs = Set<String>()
  private var functionCalls: [String: OpenAIFunctionCallAssembly] = [:]
  private var completedToolCalls: [Int: ToolCall] = [:]
  private var textParts: [OpenAITextPartKey: OpenAITextPartAssembly] = [:]
  private var textAnnotations: [OpenAITextPartKey: [Int: JSONValue]] = [:]
  private var callIDs = Set<String>()
  private var sawRefusal = false
  private var sawDoneSentinel = false

  init(configuration: OpenAIResponsesConfiguration) {
    self.configuration = configuration
  }

  mutating func process(_ event: ServerSentEvent) throws -> OpenAIResponsesProcessedEvent {
    if event.data == Data("[DONE]".utf8) {
      guard
        lifecycle == .terminal,
        !sawDoneSentinel,
        event.name == nil || event.name == "message"
      else {
        throw OpenAIResponsesProviderError.malformedStream
      }
      sawDoneSentinel = true
      return OpenAIResponsesProcessedEvent(events: [], terminalResult: nil)
    }

    guard lifecycle != .terminal, !sawDoneSentinel else {
      throw OpenAIResponsesProviderError.malformedStream
    }

    let value: JSONValue
    do {
      value = try JSONDecoder().decode(JSONValue.self, from: event.data)
    } catch {
      throw OpenAIResponsesProviderError.malformedStream
    }
    guard case .object(let object) = value else {
      throw OpenAIResponsesProviderError.malformedStream
    }

    let type = try requiredString("type", in: object)
    guard
      type.utf8.count <= 128,
      event.name == nil || event.name == "message" || event.name == type
    else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    try validateSequence(in: object)

    switch type {
    case "response.created":
      return try processCreated(object)
    case "response.queued", "response.in_progress":
      try requireStreamingResponse(object)
      return emptyResult()
    case "response.output_item.added":
      try processOutputItemAdded(object)
      return emptyResult()
    case "response.content_part.added":
      try processContentPartAdded(object)
      return emptyResult()
    case "response.content_part.done":
      try processContentPartDone(object)
      return emptyResult()
    case "response.output_text.delta":
      return try processTextDelta(object, partType: "output_text")
    case "response.output_text.done":
      try processTextDone(object, partType: "output_text", valueKey: "text")
      return emptyResult()
    case "response.output_text.annotation.added":
      try processTextAnnotation(object)
      return emptyResult()
    case "response.refusal.delta":
      sawRefusal = true
      return try processTextDelta(object, partType: "refusal")
    case "response.refusal.done":
      sawRefusal = true
      try processTextDone(object, partType: "refusal", valueKey: "refusal")
      return emptyResult()
    case "response.reasoning_summary_part.added":
      try processReasoningPartAdded(object)
      return emptyResult()
    case "response.reasoning_summary_part.done":
      try processReasoningPartDone(object)
      return emptyResult()
    case "response.reasoning_summary_text.delta":
      return try processReasoningSummaryDelta(object)
    case "response.reasoning_summary_text.done":
      try processReasoningSummaryDone(object)
      return emptyResult()
    case "response.reasoning_text.delta":
      try processReasoningTextDelta(object)
      return emptyResult()
    case "response.reasoning_text.done":
      try processReasoningTextDone(object)
      return emptyResult()
    case "response.function_call_arguments.delta":
      try processFunctionArgumentsDelta(object)
      return emptyResult()
    case "response.function_call_arguments.done":
      try processFunctionArgumentsDone(object)
      return emptyResult()
    case "response.output_item.done":
      return try processOutputItemDone(object)
    case "response.completed":
      return try processTerminal(object, expectedStatus: "completed")
    case "response.incomplete":
      return try processTerminal(object, expectedStatus: "incomplete")
    case "response.failed", "response.cancelled", "error":
      throw OpenAIResponsesProviderError.responseFailed
    default:
      throw OpenAIResponsesProviderError.malformedStream
    }
  }

  func finish() throws {
    guard lifecycle == .terminal else {
      throw OpenAIResponsesProviderError.truncatedStream
    }
  }

  private mutating func processCreated(
    _ object: [String: JSONValue]
  ) throws -> OpenAIResponsesProcessedEvent {
    guard lifecycle == .awaitingStart else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    let response = try requiredObject("response", in: object)
    let identifier = try requiredString("id", in: response)
    let status = try requiredString("status", in: response)
    guard
      isValidIdentifier(identifier),
      status == "in_progress" || status == "queued"
    else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    responseID = identifier
    lifecycle = .streaming
    return OpenAIResponsesProcessedEvent(
      events: [.started(providerResponseID: identifier)],
      terminalResult: nil
    )
  }

  private mutating func processOutputItemAdded(_ object: [String: JSONValue]) throws {
    try requireStreaming()
    let outputIndex = try requiredIndex("output_index", in: object)
    guard
      outputIndex < configuration.maximumOutputItems,
      addedOutputItems[outputIndex] == nil,
      completedOutputItems[outputIndex] == nil
    else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    let itemValue = try requiredValue("item", in: object)
    guard case .object(let item) = itemValue else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    let itemID = try requiredString("id", in: item)
    let itemType = try requiredString("type", in: item)
    guard isValidIdentifier(itemID), ["message", "reasoning", "function_call"].contains(itemType)
    else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    guard outputItemIDs.insert(itemID).inserted else {
      throw OpenAIResponsesProviderError.malformedStream
    }

    if itemType == "function_call" {
      let callID = try requiredString("call_id", in: item)
      let name = try requiredString("name", in: item)
      let arguments = try requiredString("arguments", in: item)
      guard
        isValidIdentifier(callID),
        isValidToolName(name),
        arguments.utf8.count <= configuration.maximumToolArgumentBytes,
        callIDs.insert(callID).inserted,
        functionCalls[itemID] == nil
      else {
        throw OpenAIResponsesProviderError.malformedStream
      }
      functionCalls[itemID] = OpenAIFunctionCallAssembly(
        itemID: itemID,
        outputIndex: outputIndex,
        callID: callID,
        name: name,
        argumentBytes: Data(arguments.utf8),
        finalArguments: nil,
        emitted: false
      )
    }

    addedOutputItems[outputIndex] = itemValue
  }

  private mutating func processContentPartAdded(_ object: [String: JSONValue]) throws {
    try requireStreaming()
    let itemID = try requiredString("item_id", in: object)
    let outputIndex = try requiredIndex("output_index", in: object)
    let contentIndex = try requiredIndex("content_index", in: object)
    guard contentIndex < configuration.maximumOutputItems else {
      throw OpenAIResponsesProviderError.streamLimitExceeded
    }
    try requireOutputItem(id: itemID, index: outputIndex, type: "message")
    let part = try requiredObject("part", in: object)
    let partType = try requiredString("type", in: part)
    guard partType == "output_text" || partType == "refusal" else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    let valueKey = partType == "output_text" ? "text" : "refusal"
    let initialText = try requiredString(valueKey, in: part)
    let initialBytes = Data(initialText.utf8)
    guard initialBytes.count <= configuration.maximumSSEEventBytes else {
      throw OpenAIResponsesProviderError.streamLimitExceeded
    }
    let key = OpenAITextPartKey(channel: "message", itemID: itemID, index: contentIndex)
    guard textParts[key] == nil else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    if partType == "output_text" {
      guard try requiredArray("annotations", in: part).isEmpty else {
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

  private mutating func processContentPartDone(_ object: [String: JSONValue]) throws {
    try requireStreaming()
    let itemID = try requiredString("item_id", in: object)
    let outputIndex = try requiredIndex("output_index", in: object)
    let contentIndex = try requiredIndex("content_index", in: object)
    try requireOutputItem(id: itemID, index: outputIndex, type: "message")
    let key = OpenAITextPartKey(channel: "message", itemID: itemID, index: contentIndex)
    guard var assembly = textParts[key], assembly.outputIndex == outputIndex else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    let part = try requiredObject("part", in: object)
    let partType = try requiredString("type", in: part)
    let valueKey = partType == "output_text" ? "text" : "refusal"
    guard
      partType == assembly.partType,
      let finalText = assembly.finalText,
      !assembly.partCompleted,
      try requiredString(valueKey, in: part) == finalText
    else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    if partType == "output_text" {
      try validateAnnotations(in: part, for: key)
    }
    assembly.partCompleted = true
    textParts[key] = assembly
  }

  private mutating func processTextDelta(
    _ object: [String: JSONValue],
    partType: String
  ) throws -> OpenAIResponsesProcessedEvent {
    try requireStreaming()
    let itemID = try requiredString("item_id", in: object)
    let outputIndex = try requiredIndex("output_index", in: object)
    let contentIndex = try requiredIndex("content_index", in: object)
    try requireOutputItem(id: itemID, index: outputIndex, type: "message")
    let delta = try requiredString("delta", in: object)
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

  private mutating func processTextDone(
    _ object: [String: JSONValue],
    partType: String,
    valueKey: String
  ) throws {
    try requireStreaming()
    let itemID = try requiredString("item_id", in: object)
    let outputIndex = try requiredIndex("output_index", in: object)
    let contentIndex = try requiredIndex("content_index", in: object)
    try requireOutputItem(id: itemID, index: outputIndex, type: "message")
    let text = try requiredString(valueKey, in: object)
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

  private mutating func processTextAnnotation(_ object: [String: JSONValue]) throws {
    try requireStreaming()
    let itemID = try requiredString("item_id", in: object)
    let outputIndex = try requiredIndex("output_index", in: object)
    let contentIndex = try requiredIndex("content_index", in: object)
    let annotationIndex = try requiredIndex("annotation_index", in: object)
    guard annotationIndex < configuration.maximumOutputItems else {
      throw OpenAIResponsesProviderError.streamLimitExceeded
    }
    try requireOutputItem(id: itemID, index: outputIndex, type: "message")
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
    let annotation = try requiredValue("annotation", in: object)
    guard
      case .object(let annotationObject) = annotation,
      try requiredString("type", in: annotationObject).utf8.count <= 128,
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

  private mutating func processReasoningPartAdded(_ object: [String: JSONValue]) throws {
    try requireStreaming()
    let itemID = try requiredString("item_id", in: object)
    let outputIndex = try requiredIndex("output_index", in: object)
    let summaryIndex = try requiredIndex("summary_index", in: object)
    guard summaryIndex < configuration.maximumOutputItems else {
      throw OpenAIResponsesProviderError.streamLimitExceeded
    }
    try requireOutputItem(id: itemID, index: outputIndex, type: "reasoning")
    let part = try requiredObject("part", in: object)
    guard try requiredString("type", in: part) == "summary_text" else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    let initialText = try requiredString("text", in: part)
    let initialBytes = Data(initialText.utf8)
    guard initialBytes.count <= configuration.maximumSSEEventBytes else {
      throw OpenAIResponsesProviderError.streamLimitExceeded
    }
    let key = OpenAITextPartKey(
      channel: "reasoning_summary",
      itemID: itemID,
      index: summaryIndex
    )
    guard textParts[key] == nil else {
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

  private mutating func processReasoningPartDone(_ object: [String: JSONValue]) throws {
    try requireStreaming()
    let itemID = try requiredString("item_id", in: object)
    let outputIndex = try requiredIndex("output_index", in: object)
    let summaryIndex = try requiredIndex("summary_index", in: object)
    try requireOutputItem(id: itemID, index: outputIndex, type: "reasoning")
    let key = OpenAITextPartKey(
      channel: "reasoning_summary",
      itemID: itemID,
      index: summaryIndex
    )
    guard var assembly = textParts[key], assembly.outputIndex == outputIndex else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    let part = try requiredObject("part", in: object)
    guard
      try requiredString("type", in: part) == assembly.partType,
      let finalText = assembly.finalText,
      !assembly.partCompleted,
      try requiredString("text", in: part) == finalText
    else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    assembly.partCompleted = true
    textParts[key] = assembly
  }

  private mutating func processReasoningSummaryDelta(
    _ object: [String: JSONValue]
  ) throws -> OpenAIResponsesProcessedEvent {
    try requireStreaming()
    let itemID = try requiredString("item_id", in: object)
    let outputIndex = try requiredIndex("output_index", in: object)
    let summaryIndex = try requiredIndex("summary_index", in: object)
    try requireOutputItem(id: itemID, index: outputIndex, type: "reasoning")
    let delta = try requiredString("delta", in: object)
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

  private mutating func processReasoningSummaryDone(_ object: [String: JSONValue]) throws {
    try requireStreaming()
    let itemID = try requiredString("item_id", in: object)
    let outputIndex = try requiredIndex("output_index", in: object)
    let summaryIndex = try requiredIndex("summary_index", in: object)
    try requireOutputItem(id: itemID, index: outputIndex, type: "reasoning")
    let text = try requiredString("text", in: object)
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

  private func processReasoningTextDelta(_ object: [String: JSONValue]) throws {
    try requireStreaming()
    let itemID = try requiredString("item_id", in: object)
    let outputIndex = try requiredIndex("output_index", in: object)
    _ = try requiredIndex("content_index", in: object)
    try requireOutputItem(id: itemID, index: outputIndex, type: "reasoning")
    let delta = try requiredString("delta", in: object)
    guard delta.utf8.count <= configuration.maximumSSEEventBytes else {
      throw OpenAIResponsesProviderError.streamLimitExceeded
    }
  }

  private func processReasoningTextDone(_ object: [String: JSONValue]) throws {
    try requireStreaming()
    let itemID = try requiredString("item_id", in: object)
    let outputIndex = try requiredIndex("output_index", in: object)
    _ = try requiredIndex("content_index", in: object)
    try requireOutputItem(id: itemID, index: outputIndex, type: "reasoning")
    let text = try requiredString("text", in: object)
    guard text.utf8.count <= configuration.maximumSSEEventBytes else {
      throw OpenAIResponsesProviderError.streamLimitExceeded
    }
  }

  private mutating func processFunctionArgumentsDelta(_ object: [String: JSONValue]) throws {
    try requireStreaming()
    let itemID = try requiredString("item_id", in: object)
    let outputIndex = try requiredIndex("output_index", in: object)
    let delta = try requiredString("delta", in: object)
    guard var assembly = functionCalls[itemID], assembly.outputIndex == outputIndex else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    guard assembly.finalArguments == nil, !assembly.emitted else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    let deltaBytes = Data(delta.utf8)
    let (newCount, overflowed) = assembly.argumentBytes.count.addingReportingOverflow(
      deltaBytes.count
    )
    guard !overflowed, newCount <= configuration.maximumToolArgumentBytes else {
      throw OpenAIResponsesProviderError.streamLimitExceeded
    }
    assembly.argumentBytes.append(deltaBytes)
    functionCalls[itemID] = assembly
  }

  private mutating func processFunctionArgumentsDone(_ object: [String: JSONValue]) throws {
    try requireStreaming()
    let itemID = try requiredString("item_id", in: object)
    let outputIndex = try requiredIndex("output_index", in: object)
    let name = try requiredString("name", in: object)
    let arguments = try requiredString("arguments", in: object)
    guard var assembly = functionCalls[itemID], assembly.outputIndex == outputIndex else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    guard
      assembly.finalArguments == nil,
      !assembly.emitted,
      assembly.name == name,
      arguments.utf8.count <= configuration.maximumToolArgumentBytes
    else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    if let callID = try optionalString("call_id", in: object) {
      guard callID == assembly.callID else {
        throw OpenAIResponsesProviderError.malformedStream
      }
    }
    let finalBytes = Data(arguments.utf8)
    guard assembly.argumentBytes.isEmpty || assembly.argumentBytes == finalBytes else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    _ = try decodeArguments(arguments)
    assembly.argumentBytes = finalBytes
    assembly.finalArguments = arguments
    functionCalls[itemID] = assembly
  }

  private mutating func processOutputItemDone(
    _ object: [String: JSONValue]
  ) throws -> OpenAIResponsesProcessedEvent {
    try requireStreaming()
    let outputIndex = try requiredIndex("output_index", in: object)
    guard
      outputIndex < configuration.maximumOutputItems,
      let addedValue = addedOutputItems[outputIndex],
      completedOutputItems[outputIndex] == nil
    else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    let completedValue = try requiredValue("item", in: object)
    guard
      case .object(let added) = addedValue,
      case .object(let completed) = completedValue,
      try requiredString("id", in: added) == requiredString("id", in: completed),
      try requiredString("type", in: added) == requiredString("type", in: completed)
    else {
      throw OpenAIResponsesProviderError.malformedStream
    }

    let type = try requiredString("type", in: completed)
    switch type {
    case "function_call":
      let itemID = try requiredString("id", in: completed)
      let callID = try requiredString("call_id", in: completed)
      let name = try requiredString("name", in: completed)
      let arguments = try requiredString("arguments", in: completed)
      guard var assembly = functionCalls[itemID] else {
        throw OpenAIResponsesProviderError.malformedStream
      }
      guard
        assembly.outputIndex == outputIndex,
        assembly.callID == callID,
        assembly.name == name,
        assembly.finalArguments == arguments,
        !assembly.emitted,
        try optionalString("status", in: completed).map({ $0 == "completed" }) ?? true
      else {
        throw OpenAIResponsesProviderError.malformedStream
      }
      let argumentsObject = try decodeArguments(arguments)
      assembly.emitted = true
      functionCalls[itemID] = assembly
      completedToolCalls[outputIndex] = ToolCall(
        id: ToolCallID(rawValue: callID),
        name: name,
        arguments: argumentsObject
      )
    case "reasoning":
      try validateCompletedReasoning(completed, outputIndex: outputIndex)
      if let status = try optionalString("status", in: completed) {
        guard status == "completed" || status == "incomplete" else {
          throw OpenAIResponsesProviderError.malformedStream
        }
      }
    case "message":
      try validateCompletedMessage(completed, outputIndex: outputIndex)
      if let status = try optionalString("status", in: completed) {
        guard status == "completed" || status == "incomplete" else {
          throw OpenAIResponsesProviderError.malformedStream
        }
      }
    default:
      throw OpenAIResponsesProviderError.malformedStream
    }

    completedOutputItems[outputIndex] = completedValue
    return OpenAIResponsesProcessedEvent(events: [], terminalResult: nil)
  }

  private func validateCompletedMessage(
    _ item: [String: JSONValue],
    outputIndex: Int
  ) throws {
    let itemID = try requiredString("id", in: item)
    guard try requiredString("role", in: item) == "assistant" else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    let content = try requiredArray("content", in: item)
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
        try requiredString("type", in: part) == assembly.partType
      else {
        throw OpenAIResponsesProviderError.malformedStream
      }
      let valueKey = assembly.partType == "output_text" ? "text" : "refusal"
      guard try requiredString(valueKey, in: part) == finalText else {
        throw OpenAIResponsesProviderError.malformedStream
      }
      if assembly.partType == "output_text" {
        try validateAnnotations(in: part, for: key)
      }
    }
  }

  private func validateAnnotations(
    in part: [String: JSONValue],
    for key: OpenAITextPartKey
  ) throws {
    let completedAnnotations = try requiredArray("annotations", in: part)
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

  private func validateCompletedReasoning(
    _ item: [String: JSONValue],
    outputIndex: Int
  ) throws {
    let itemID = try requiredString("id", in: item)
    let summary = try requiredArray("summary", in: item)
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
        try requiredString("type", in: part) == "summary_text",
        try requiredString("text", in: part) == finalText
      else {
        throw OpenAIResponsesProviderError.malformedStream
      }
    }
  }

  private mutating func processTerminal(
    _ object: [String: JSONValue],
    expectedStatus: String
  ) throws -> OpenAIResponsesProcessedEvent {
    try requireStreaming()
    let response = try requiredObject("response", in: object)
    try validateResponse(response, expectedStatus: expectedStatus)

    let output = try requiredArray("output", in: response)
    guard output.count == completedOutputItems.count else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    for (index, value) in output.enumerated() {
      guard completedOutputItems[index] == value else {
        throw OpenAIResponsesProviderError.malformedStream
      }
    }

    for assembly in functionCalls.values {
      guard assembly.finalArguments != nil, assembly.emitted else {
        throw OpenAIResponsesProviderError.malformedStream
      }
    }

    let stopReason: InferenceStopReason
    if expectedStatus == "incomplete" {
      stopReason = try incompleteStopReason(response)
    } else if !functionCalls.isEmpty {
      stopReason = .toolCalls
    } else if sawRefusal {
      stopReason = .contentFilter
    } else {
      stopReason = .stop
    }

    if configuration.privacyMode == .localEphemeralReplay,
      stopReason == .toolCalls
    {
      for itemValue in output {
        guard case .object(let item) = itemValue else {
          throw OpenAIResponsesProviderError.malformedStream
        }
        if item["type"] == .string("reasoning") {
          guard
            case .string(let encryptedContent)? = item["encrypted_content"],
            !encryptedContent.isEmpty,
            encryptedContent.utf8.count <= configuration.maximumLocalStateBytes
          else {
            throw OpenAIResponsesProviderError.encryptedReasoningUnavailable
          }
        }
      }
    }

    var events: [InferenceStreamEvent] = []
    for outputIndex in completedToolCalls.keys.sorted() {
      guard let call = completedToolCalls[outputIndex] else {
        throw OpenAIResponsesProviderError.malformedStream
      }
      events.append(.toolCall(call))
    }
    if let usage = try usage(in: response) {
      events.append(.usage(usage))
    }
    events.append(.completed(stopReason))

    let encodedOutputBytes =
      configuration.privacyMode == .localEphemeralReplay && stopReason == .toolCalls
      ? try measureOutputItems(output)
      : 0
    guard let responseID else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    lifecycle = .terminal
    return OpenAIResponsesProcessedEvent(
      events: events,
      terminalResult: OpenAIResponsesStreamResult(
        responseID: responseID,
        stopReason: stopReason,
        outputItems: output,
        encodedOutputBytes: encodedOutputBytes
      )
    )
  }

  private func validateResponse(
    _ response: [String: JSONValue],
    expectedStatus: String
  ) throws {
    let terminalID = try requiredString("id", in: response)
    let status = try requiredString("status", in: response)
    guard terminalID == responseID, status == expectedStatus else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    guard addedOutputItems.count == completedOutputItems.count else {
      throw OpenAIResponsesProviderError.malformedStream
    }
  }

  private func incompleteStopReason(
    _ response: [String: JSONValue]
  ) throws -> InferenceStopReason {
    guard case .object(let details)? = response["incomplete_details"] else {
      return .other("incomplete")
    }
    let reason = try requiredString("reason", in: details)
    switch reason {
    case "max_output_tokens":
      return .length
    case "content_filter":
      return .contentFilter
    default:
      return .other("incomplete")
    }
  }

  private func usage(in response: [String: JSONValue]) throws -> InferenceUsage? {
    guard let usageValue = response["usage"], usageValue != .null else {
      return nil
    }
    guard case .object(let usage) = usageValue else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    let inputTokens = try requiredUnsigned("input_tokens", in: usage)
    let outputTokens = try requiredUnsigned("output_tokens", in: usage)

    var cachedTokens: UInt64 = 0
    if let detailsValue = usage["input_tokens_details"], detailsValue != .null {
      guard case .object(let details) = detailsValue else {
        throw OpenAIResponsesProviderError.malformedStream
      }
      cachedTokens = try optionalUnsigned("cached_tokens", in: details) ?? 0
    }

    var reasoningTokens: UInt64 = 0
    if let detailsValue = usage["output_tokens_details"], detailsValue != .null {
      guard case .object(let details) = detailsValue else {
        throw OpenAIResponsesProviderError.malformedStream
      }
      reasoningTokens = try optionalUnsigned("reasoning_tokens", in: details) ?? 0
    }

    return InferenceUsage(
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      cachedInputTokens: cachedTokens,
      reasoningTokens: reasoningTokens
    )
  }

  private func measureOutputItems(_ output: [JSONValue]) throws -> Int {
    guard output.count <= configuration.maximumOutputItems else {
      throw OpenAIResponsesProviderError.streamLimitExceeded
    }
    let encoder = JSONEncoder()
    var byteCount = 0
    for item in output {
      guard
        OpenAIJSONValidator.measuredBytes(
          for: item,
          maximumDepth: configuration.maximumJSONDepth,
          maximumNodes: configuration.maximumJSONNodes,
          maximumStringBytes: configuration.maximumLocalStateBytes
        ) != nil
      else {
        throw OpenAIResponsesProviderError.streamLimitExceeded
      }
      let data: Data
      do {
        data = try encoder.encode(item)
      } catch {
        throw OpenAIResponsesProviderError.malformedStream
      }
      let (newCount, overflowed) = byteCount.addingReportingOverflow(data.count)
      guard !overflowed, newCount <= configuration.maximumLocalStateBytes else {
        throw OpenAIResponsesProviderError.localStateLimitExceeded
      }
      byteCount = newCount
    }
    return byteCount
  }

  private func decodeArguments(_ arguments: String) throws -> [String: JSONValue] {
    let data = Data(arguments.utf8)
    guard data.count <= configuration.maximumToolArgumentBytes else {
      throw OpenAIResponsesProviderError.streamLimitExceeded
    }
    let value: JSONValue
    do {
      value = try JSONDecoder().decode(JSONValue.self, from: data)
    } catch {
      throw OpenAIResponsesProviderError.malformedStream
    }
    guard
      case .object(let object) = value,
      OpenAIJSONValidator.measuredBytes(
        for: value,
        maximumDepth: configuration.maximumJSONDepth,
        maximumNodes: configuration.maximumJSONNodes,
        maximumStringBytes: configuration.maximumToolArgumentBytes
      ) != nil
    else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    return object
  }

  private func requireStreamingResponse(_ object: [String: JSONValue]) throws {
    try requireStreaming()
    let response = try requiredObject("response", in: object)
    guard try requiredString("id", in: response) == responseID else {
      throw OpenAIResponsesProviderError.malformedStream
    }
  }

  private func requireStreaming() throws {
    guard lifecycle == .streaming else {
      throw OpenAIResponsesProviderError.malformedStream
    }
  }

  private func requireOutputItem(id: String, index: Int, type: String) throws {
    guard let value = addedOutputItems[index], case .object(let item) = value else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    guard
      try requiredString("id", in: item) == id,
      try requiredString("type", in: item) == type,
      completedOutputItems[index] == nil
    else {
      throw OpenAIResponsesProviderError.malformedStream
    }
  }

  private mutating func validateSequence(in object: [String: JSONValue]) throws {
    guard case .integer(let sequenceNumber)? = object["sequence_number"], sequenceNumber >= 0 else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    if let lastSequenceNumber {
      guard sequenceNumber > lastSequenceNumber else {
        throw OpenAIResponsesProviderError.malformedStream
      }
    }
    lastSequenceNumber = sequenceNumber
  }

  private func requiredValue(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> JSONValue {
    guard let value = object[key] else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    return value
  }

  private func requiredString(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> String {
    guard case .string(let value)? = object[key] else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    return value
  }

  private func optionalString(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> String? {
    guard let value = object[key], value != .null else { return nil }
    guard case .string(let string) = value else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    return string
  }

  private func requiredObject(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> [String: JSONValue] {
    guard case .object(let value)? = object[key] else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    return value
  }

  private func requiredArray(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> [JSONValue] {
    guard case .array(let value)? = object[key] else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    return value
  }

  private func requiredIndex(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> Int {
    guard
      case .integer(let value)? = object[key],
      value >= 0,
      let index = Int(exactly: value)
    else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    return index
  }

  private func requiredUnsigned(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> UInt64 {
    guard case .integer(let value)? = object[key], value >= 0 else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    return UInt64(value)
  }

  private func optionalUnsigned(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> UInt64? {
    guard let value = object[key], value != .null else { return nil }
    guard case .integer(let integer) = value, integer >= 0 else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    return UInt64(integer)
  }

  private func isValidToolName(_ value: String) -> Bool {
    let bytes = value.utf8
    guard !bytes.isEmpty, bytes.count <= 64 else { return false }
    return bytes.allSatisfy { byte in
      (0x30...0x39).contains(byte)
        || (0x41...0x5A).contains(byte)
        || (0x61...0x7A).contains(byte)
        || byte == 0x5F
        || byte == 0x2D
    }
  }

  private func isValidIdentifier(_ value: String) -> Bool {
    let bytes = value.utf8
    guard !bytes.isEmpty, bytes.count <= configuration.maximumIdentifierBytes else {
      return false
    }
    return bytes.allSatisfy { byte in
      byte >= 0x21 && byte <= 0x7E
    }
  }

  private func emptyResult() -> OpenAIResponsesProcessedEvent {
    OpenAIResponsesProcessedEvent(events: [], terminalResult: nil)
  }
}
