import Foundation
import HexCore

struct OpenAIResponsesStreamProcessor {
  private let configuration: OpenAIResponsesConfiguration
  private let toolChoice: ToolChoice
  private let allowsParallelToolCalls: Bool
  private let declaredToolNames: Set<String>
  private var lifecycle = OpenAIResponseLifecycle.awaitingStart
  private var responseID: String?
  private var lastSequenceNumber: Int64?
  private var addedOutputItems: [Int: JSONValue] = [:]
  private var completedOutputItems: [Int: JSONValue] = [:]
  private var outputItemIDs = Set<String>()
  private var functionCalls: [String: OpenAIFunctionCallAssembly] = [:]
  private var completedToolCalls: [Int: ToolCall] = [:]
  private var textAccumulator: OpenAIResponsesTextAccumulator
  private var reasoningAccumulator: OpenAIResponsesReasoningAccumulator
  private let fields = OpenAIResponsesStreamFields()

  private var callIDs = Set<String>()
  private var sawRefusal = false
  private var sawDoneSentinel = false
  private(set) var rejectionCode = "unspecified"

  private var streamContext: OpenAIResponsesStreamContext {
    .init(
      lifecycle: lifecycle, addedOutputItems: addedOutputItems,
      completedOutputItems: completedOutputItems)
  }

  init(
    configuration: OpenAIResponsesConfiguration,
    tools: [ToolDefinition],
    toolChoice: ToolChoice,
    allowsParallelToolCalls: Bool
  ) {
    self.configuration = configuration
    textAccumulator = OpenAIResponsesTextAccumulator(configuration: configuration)
    reasoningAccumulator = OpenAIResponsesReasoningAccumulator(configuration: configuration)
    self.toolChoice = toolChoice
    self.allowsParallelToolCalls = allowsParallelToolCalls
    declaredToolNames = Set(tools.map(\.name))
  }

  mutating func process(_ event: ServerSentEvent) throws -> OpenAIResponsesProcessedEvent {
    rejectionCode = "unspecified"
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

    try OpenAIJSONStructuralPreflight.validateObjectRoot(
      event.data,
      maximumDepth: configuration.maximumJSONDepth,
      maximumNodes: configuration.maximumJSONNodes
    )
    let value: JSONValue
    do {
      value = try JSONDecoder().decode(JSONValue.self, from: event.data)
    } catch {
      throw OpenAIResponsesProviderError.malformedStream
    }
    guard case .object(let object) = value else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    guard
      OpenAIJSONValidator.measuredBytes(
        for: value,
        maximumDepth: configuration.maximumJSONDepth,
        maximumNodes: configuration.maximumJSONNodes,
        maximumStringBytes: configuration.maximumSSEEventBytes
      ) != nil
    else {
      throw OpenAIResponsesProviderError.streamLimitExceeded
    }

    let type = try fields.requiredString("type", in: object)
    guard
      type.utf8.count <= 128,
      event.name == nil || event.name == "message" || event.name == type
    else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    if isIgnorableMetadataEvent(type) {
      try validateOptionalSequence(in: object)
      return emptyResult()
    }
    try validateSequence(in: object)
    if isOutputEvent(type) {
      try beginOutput()
    }

    switch type {
    case "response.created":
      return try processCreated(object)
    case "response.queued":
      try processQueued(object)
      return emptyResult()
    case "response.in_progress":
      try processInProgress(object)
      return emptyResult()
    case "response.output_item.added":
      try processOutputItemAdded(object)
      return emptyResult()
    case "response.content_part.added":
      try textAccumulator.processContentPartAdded(object, context: streamContext)
      return emptyResult()
    case "response.content_part.done":
      try textAccumulator.processContentPartDone(object, context: streamContext)
      return emptyResult()
    case "response.output_text.delta":
      return try textAccumulator.processTextDelta(
        object, context: streamContext, partType: "output_text")
    case "response.output_text.done":
      try textAccumulator.processTextDone(
        object, context: streamContext, partType: "output_text", valueKey: "text")
      return emptyResult()
    case "response.output_text.annotation.added":
      try textAccumulator.processTextAnnotation(object, context: streamContext)
      return emptyResult()
    case "response.refusal.delta":
      sawRefusal = true
      return try textAccumulator.processTextDelta(
        object, context: streamContext, partType: "refusal")
    case "response.refusal.done":
      sawRefusal = true
      try textAccumulator.processTextDone(
        object, context: streamContext, partType: "refusal", valueKey: "refusal")
      return emptyResult()
    case "response.reasoning_summary_part.added":
      try reasoningAccumulator.processReasoningPartAdded(object, context: streamContext)
      return emptyResult()
    case "response.reasoning_summary_part.done":
      try reasoningAccumulator.processReasoningPartDone(object, context: streamContext)
      return emptyResult()
    case "response.reasoning_summary_text.delta":
      return try reasoningAccumulator.processReasoningSummaryDelta(object, context: streamContext)
    case "response.reasoning_summary_text.done":
      try reasoningAccumulator.processReasoningSummaryDone(object, context: streamContext)
      return emptyResult()
    case "response.reasoning_text.delta":
      try reasoningAccumulator.processReasoningTextDelta(object, context: streamContext)
      return emptyResult()
    case "response.reasoning_text.done":
      try reasoningAccumulator.processReasoningTextDone(object, context: streamContext)
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
    case "response.failed":
      try processFailure(object, expectedStatus: "failed")
      throw OpenAIResponsesProviderError.responseFailed
    case "response.cancelled":
      try processFailure(object, expectedStatus: "cancelled")
      throw OpenAIResponsesProviderError.responseFailed
    case "error":
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
    let response = try fields.requiredObject("response", in: object)
    let identifier = try fields.requiredString("id", in: response)
    let status = try fields.requiredString("status", in: response)
    guard
      isValidIdentifier(identifier),
      status == "in_progress" || status == "queued"
    else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    responseID = identifier
    lifecycle = status == "queued" ? .createdQueued : .createdInProgress
    return OpenAIResponsesProcessedEvent(
      events: [.started(providerResponseID: identifier)],
      terminalResult: nil
    )
  }

  private mutating func processQueued(_ object: [String: JSONValue]) throws {
    try validateProgressResponse(object, expectedStatus: "queued")
    guard lifecycle == .createdQueued else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    lifecycle = .queued
  }

  private mutating func processInProgress(_ object: [String: JSONValue]) throws {
    try validateProgressResponse(object, expectedStatus: "in_progress")
    switch lifecycle {
    case .createdQueued, .createdInProgress, .queued:
      lifecycle = .inProgress
    case .awaitingStart, .inProgress, .output, .terminal:
      throw OpenAIResponsesProviderError.malformedStream
    }
  }

  private mutating func beginOutput() throws {
    switch lifecycle {
    case .createdInProgress, .inProgress, .output:
      lifecycle = .output
    case .awaitingStart, .createdQueued, .queued, .terminal:
      throw OpenAIResponsesProviderError.malformedStream
    }
  }

  private func isOutputEvent(_ type: String) -> Bool {
    switch type {
    case "response.output_item.added",
      "response.content_part.added",
      "response.content_part.done",
      "response.output_text.delta",
      "response.output_text.done",
      "response.output_text.annotation.added",
      "response.refusal.delta",
      "response.refusal.done",
      "response.reasoning_summary_part.added",
      "response.reasoning_summary_part.done",
      "response.reasoning_summary_text.delta",
      "response.reasoning_summary_text.done",
      "response.reasoning_text.delta",
      "response.reasoning_text.done",
      "response.function_call_arguments.delta",
      "response.function_call_arguments.done",
      "response.output_item.done":
      true
    default:
      false
    }
  }

  private func isIgnorableMetadataEvent(_ type: String) -> Bool {
    switch type {
    case "keepalive":
      // The subscription route emits these while preparing a long response. They carry no
      // output or tool authority, and the ordinary JSON, event and optional-sequence bounds apply.
      configuration.service == .chatGPTCodexSubscription
    case "codex.response.metadata", "response.metadata", "responsesapi.websocket_timing":
      true
    default:
      false
    }
  }

  private mutating func processFailure(
    _ object: [String: JSONValue],
    expectedStatus: String
  ) throws {
    switch lifecycle {
    case .createdQueued, .createdInProgress, .queued, .inProgress, .output:
      break
    case .awaitingStart, .terminal:
      throw OpenAIResponsesProviderError.malformedStream
    }
    let response = try fields.requiredObject("response", in: object)
    guard
      try fields.requiredString("id", in: response) == responseID,
      try fields.requiredString("status", in: response) == expectedStatus
    else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    lifecycle = .terminal
  }

  private func validateProgressResponse(
    _ object: [String: JSONValue],
    expectedStatus: String
  ) throws {
    try streamContext.requireStreaming()
    let response = try fields.requiredObject("response", in: object)
    guard
      try fields.requiredString("id", in: response) == responseID,
      try fields.requiredString("status", in: response) == expectedStatus
    else {
      throw OpenAIResponsesProviderError.malformedStream
    }
  }

  private mutating func processOutputItemAdded(_ object: [String: JSONValue]) throws {
    try streamContext.requireStreaming()
    let outputIndex = try fields.requiredIndex("output_index", in: object)
    guard
      outputIndex < configuration.maximumOutputItems,
      outputIndex == addedOutputItems.count,
      addedOutputItems[outputIndex] == nil,
      completedOutputItems[outputIndex] == nil,
      outputIndex == 0 || completedOutputItems[outputIndex - 1] != nil
    else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    let itemValue = try fields.requiredValue("item", in: object)
    guard case .object(let item) = itemValue else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    let itemID = try fields.requiredString("id", in: item)
    let itemType = try fields.requiredString("type", in: item)
    guard isValidIdentifier(itemID), ["message", "reasoning", "function_call"].contains(itemType)
    else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    guard outputItemIDs.insert(itemID).inserted else {
      throw OpenAIResponsesProviderError.malformedStream
    }

    switch itemType {
    case "message":
      guard
        try fields.requiredString("role", in: item) == "assistant",
        try fields.requiredString("status", in: item) == "in_progress",
        try fields.requiredArray("content", in: item).isEmpty
      else {
        throw OpenAIResponsesProviderError.malformedStream
      }
    case "reasoning":
      guard
        try fields.requiredArray("summary", in: item).isEmpty,
        try fields.optionalArray("content", in: item)?.isEmpty ?? true,
        try fields.optionalString("status", in: item).map({ $0 == "in_progress" }) ?? true
      else {
        throw OpenAIResponsesProviderError.malformedStream
      }
    case "function_call":
      let callID = try fields.requiredString("call_id", in: item)
      let name = try fields.requiredString("name", in: item)
      let arguments = try fields.requiredString("arguments", in: item)
      guard
        isValidIdentifier(callID),
        isValidToolName(name),
        isAllowedToolName(name),
        try fields.optionalString("status", in: item).map({ $0 == "in_progress" }) ?? true,
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
    default:
      throw OpenAIResponsesProviderError.malformedStream
    }

    addedOutputItems[outputIndex] = itemValue
  }

  private mutating func processFunctionArgumentsDelta(_ object: [String: JSONValue]) throws {
    try streamContext.requireStreaming()
    let itemID = try fields.requiredString("item_id", in: object)
    let outputIndex = try fields.requiredIndex("output_index", in: object)
    let delta = try fields.requiredString("delta", in: object)
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
    try streamContext.requireStreaming()
    rejectionCode = "arguments_done_identity"
    let itemID = try fields.requiredString("item_id", in: object)
    let outputIndex = try fields.requiredIndex("output_index", in: object)
    let name = try object["name"].map { _ in try fields.requiredString("name", in: object) }
    let arguments = try fields.requiredString("arguments", in: object)
    guard var assembly = functionCalls[itemID], assembly.outputIndex == outputIndex else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    // Codex may omit the redundant name on this event. The item ID/index bind arguments to
    // the already validated call, and output_item.done must still repeat the same name/call ID.
    // The public Responses schema requires name, so retain that contract on the API route.
    rejectionCode = "arguments_done_name"
    guard name != nil || configuration.service == .chatGPTCodexSubscription,
      name == nil || name == assembly.name
    else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    rejectionCode = "arguments_done_lifecycle_or_size"
    guard
      assembly.finalArguments == nil,
      !assembly.emitted,
      arguments.utf8.count <= configuration.maximumToolArgumentBytes
    else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    if let callID = try fields.optionalString("call_id", in: object) {
      rejectionCode = "arguments_done_call_id"
      guard callID == assembly.callID else {
        throw OpenAIResponsesProviderError.malformedStream
      }
    }
    let finalBytes = Data(arguments.utf8)
    rejectionCode = "arguments_done_delta_mismatch"
    guard assembly.argumentBytes.isEmpty || assembly.argumentBytes == finalBytes else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    rejectionCode = "arguments_done_invalid_json"
    _ = try decodeArguments(arguments)
    assembly.argumentBytes = finalBytes
    assembly.finalArguments = arguments
    functionCalls[itemID] = assembly
  }

  private mutating func processOutputItemDone(
    _ object: [String: JSONValue]
  ) throws -> OpenAIResponsesProcessedEvent {
    try streamContext.requireStreaming()
    let outputIndex = try fields.requiredIndex("output_index", in: object)
    guard
      outputIndex < configuration.maximumOutputItems,
      let addedValue = addedOutputItems[outputIndex],
      completedOutputItems[outputIndex] == nil
    else {
      throw OpenAIResponsesProviderError.malformedStream
    }
    let completedValue = try fields.requiredValue("item", in: object)
    guard
      case .object(let added) = addedValue,
      case .object(let completed) = completedValue,
      try fields.requiredString("id", in: added) == fields.requiredString("id", in: completed),
      try fields.requiredString("type", in: added) == fields.requiredString("type", in: completed)
    else {
      throw OpenAIResponsesProviderError.malformedStream
    }

    let type = try fields.requiredString("type", in: completed)
    switch type {
    case "function_call":
      let itemID = try fields.requiredString("id", in: completed)
      let callID = try fields.requiredString("call_id", in: completed)
      let name = try fields.requiredString("name", in: completed)
      let arguments = try fields.requiredString("arguments", in: completed)
      guard var assembly = functionCalls[itemID] else {
        throw OpenAIResponsesProviderError.malformedStream
      }
      guard
        assembly.outputIndex == outputIndex,
        assembly.callID == callID,
        assembly.name == name,
        assembly.finalArguments == arguments,
        !assembly.emitted,
        try fields.optionalString("status", in: completed).map({ $0 == "completed" }) ?? true
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
      try reasoningAccumulator.validateCompletedReasoning(completed, outputIndex: outputIndex)
      let reasoningStatus = try fields.optionalString("status", in: completed)
      guard
        reasoningStatus == nil || reasoningStatus == "completed" || reasoningStatus == "incomplete"
      else {
        throw OpenAIResponsesProviderError.malformedStream
      }
    case "message":
      try textAccumulator.validateCompletedMessage(completed, outputIndex: outputIndex)
      let messageStatus = try fields.requiredString("status", in: completed)
      guard messageStatus == "completed" || messageStatus == "incomplete" else {
        throw OpenAIResponsesProviderError.malformedStream
      }
    default:
      throw OpenAIResponsesProviderError.malformedStream
    }

    completedOutputItems[outputIndex] = completedValue
    return OpenAIResponsesProcessedEvent(events: [], terminalResult: nil)
  }

  private mutating func processTerminal(
    _ object: [String: JSONValue],
    expectedStatus: String
  ) throws -> OpenAIResponsesProcessedEvent {
    switch lifecycle {
    case .createdInProgress, .inProgress, .output:
      break
    case .awaitingStart, .createdQueued, .queued, .terminal:
      throw reject("terminal.lifecycle")
    }
    let response = try fields.requiredObject("response", in: object)
    do {
      try validateResponse(response, expectedStatus: expectedStatus)
    } catch {
      rejectionCode = "terminal.response"
      throw error
    }

    let output = try reconciledTerminalOutput(in: response)

    for value in output {
      if expectedStatus == "completed", case .object(let item) = value,
        item["type"] != .string("function_call")
      {
        // Reasoning status is optional in Responses. A validated output_item.done establishes
        // completion when absent; an explicit incomplete/in-progress status still fails here.
        let status = try fields.optionalString("status", in: item)
        let completed =
          status == "completed" || (status == nil && item["type"] == .string("reasoning"))
        guard completed else {
          throw reject("terminal.item-status")
        }
      }
    }

    for assembly in functionCalls.values {
      guard assembly.finalArguments != nil, assembly.emitted else {
        throw reject("terminal.function-assembly")
      }
    }
    guard expectedStatus != "incomplete" || functionCalls.isEmpty else {
      throw reject("terminal.incomplete-function")
    }
    guard expectedStatus != "completed" || hasAssistantTurnContent() else {
      throw reject("terminal.assistant-content")
    }
    if expectedStatus == "completed" {
      do {
        try validateCompletedToolChoice()
      } catch {
        rejectionCode = "terminal.tool-choice"
        throw error
      }
      guard allowsParallelToolCalls || completedToolCalls.count <= 1 else {
        throw reject("terminal.parallel-tool-calls")
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
            rejectionCode = "terminal.encrypted-reasoning"
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
    do {
      if let usage = try usage(in: response) {
        events.append(.usage(usage))
      }
    } catch {
      rejectionCode = "terminal.usage"
      throw error
    }
    events.append(.completed(stopReason))

    let encodedOutputBytes: Int
    switch configuration.privacyMode {
    case .serverManagedContinuation:
      encodedOutputBytes = try measureOutputItems(
        output,
        maximumBytes: configuration.maximumServerStateBytes
      )
    case .localEphemeralReplay:
      if stopReason == .toolCalls {
        encodedOutputBytes = try measureOutputItems(
          output,
          maximumBytes: configuration.maximumLocalStateBytes
        )
      } else {
        encodedOutputBytes = 0
      }
    }
    guard let responseID else {
      throw reject("terminal.response-id")
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

  private mutating func reconciledTerminalOutput(
    in response: [String: JSONValue]
  ) throws -> [JSONValue] {
    // The ChatGPT Codex stream defines output_item.done as the content authority. Its terminal
    // response is metadata-only and may omit or redact the output snapshot entirely.
    if configuration.service == .chatGPTCodexSubscription {
      return try streamedOutputItemsInOrder()
    }

    let terminalOutput = try fields.requiredArray("output", in: response)
    guard terminalOutput.count == completedOutputItems.count else {
      let completedIndices = completedOutputItems.keys.sorted().prefix(8).map(String.init)
      throw reject(
        "terminal.output-count.terminal-\(terminalOutput.count).streamed-\(completedOutputItems.count)"
          + ".indices-\(completedIndices.joined(separator: ","))"
      )
    }
    for (index, value) in terminalOutput.enumerated() {
      guard completedOutputItems[index] == value else {
        throw reject("terminal.output-mismatch")
      }
    }
    return terminalOutput
  }

  private func streamedOutputItemsInOrder() throws -> [JSONValue] {
    var output: [JSONValue] = []
    output.reserveCapacity(completedOutputItems.count)
    for index in 0..<completedOutputItems.count {
      guard let item = completedOutputItems[index] else {
        throw OpenAIResponsesProviderError.malformedStream
      }
      output.append(item)
    }
    return output
  }

  private mutating func reject(_ code: String) -> OpenAIResponsesProviderError {
    rejectionCode = code
    return .malformedStream
  }

  private func validateResponse(
    _ response: [String: JSONValue],
    expectedStatus: String
  ) throws {
    let terminalID = try fields.requiredString("id", in: response)
    let status = try fields.requiredString("status", in: response)
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
    let reason = try fields.requiredString("reason", in: details)
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
    let inputTokens = try fields.requiredUnsigned("input_tokens", in: usage)
    let outputTokens = try fields.requiredUnsigned("output_tokens", in: usage)

    var cachedTokens: UInt64 = 0
    if let detailsValue = usage["input_tokens_details"], detailsValue != .null {
      guard case .object(let details) = detailsValue else {
        throw OpenAIResponsesProviderError.malformedStream
      }
      cachedTokens = try fields.optionalUnsigned("cached_tokens", in: details) ?? 0
    }

    var reasoningTokens: UInt64 = 0
    if let detailsValue = usage["output_tokens_details"], detailsValue != .null {
      guard case .object(let details) = detailsValue else {
        throw OpenAIResponsesProviderError.malformedStream
      }
      reasoningTokens = try fields.optionalUnsigned("reasoning_tokens", in: details) ?? 0
    }

    guard cachedTokens <= inputTokens, reasoningTokens <= outputTokens else {
      throw OpenAIResponsesProviderError.malformedStream
    }

    return InferenceUsage(
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      cachedInputTokens: cachedTokens,
      reasoningTokens: reasoningTokens
    )
  }

  private func measureOutputItems(
    _ output: [JSONValue],
    maximumBytes: Int
  ) throws -> Int {
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
          maximumStringBytes: maximumBytes
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
      guard !overflowed, newCount <= maximumBytes else {
        throw OpenAIResponsesProviderError.continuationStateLimitExceeded
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
    try OpenAIJSONStructuralPreflight.validateObjectRoot(
      data,
      maximumDepth: configuration.maximumJSONDepth,
      maximumNodes: configuration.maximumJSONNodes
    )
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

  private mutating func validateOptionalSequence(in object: [String: JSONValue]) throws {
    guard object["sequence_number"] != nil else { return }
    try validateSequence(in: object)
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

  private func isAllowedToolName(_ value: String) -> Bool {
    switch toolChoice {
    case .automatic, .required:
      declaredToolNames.contains(value)
    case .none:
      false
    case .named(let name):
      value == name && declaredToolNames.contains(value)
    }
  }

  private func validateCompletedToolChoice() throws {
    switch toolChoice {
    case .automatic, .none:
      return
    case .required:
      guard !completedToolCalls.isEmpty else {
        throw OpenAIResponsesProviderError.malformedStream
      }
    case .named(let name):
      guard completedToolCalls.values.contains(where: { $0.name == name }) else {
        throw OpenAIResponsesProviderError.malformedStream
      }
    }
  }

  private func hasAssistantTurnContent() -> Bool {
    if !completedToolCalls.isEmpty {
      return true
    }
    return textAccumulator.hasAssistantContent
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
