import Foundation
import HexCore

extension AgentRuntime {
  func validateRequest(_ request: AgentRunRequest) throws {
    guard !request.modelID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AgentRuntimeError.invalidRequest("A model ID is required.")
    }
    guard !request.initialMessages.isEmpty else {
      throw AgentRuntimeError.invalidRequest("At least one initial message is required.")
    }

    let allInitialMessages = request.contextMessages + request.initialMessages
    var messageIDs: Set<MessageID> = []
    for message in allInitialMessages {
      guard messageIDs.insert(message.id).inserted else {
        throw AgentRuntimeError.invalidRequest("Initial and context message IDs must be unique.")
      }
      guard !message.content.isEmpty else {
        throw AgentRuntimeError.invalidRequest(
          "Initial and context messages cannot have empty content."
        )
      }
    }
    _ = try initialToolCallIDs(in: allInitialMessages)

    let initialInputBytes: Int
    do {
      initialInputBytes = try JSONEncoder().encode(allInitialMessages).count
    } catch {
      throw AgentRuntimeError.invalidRequest("Initial messages must be serializable.")
    }
    guard initialInputBytes <= configuration.budget.maxInitialInputBytes else {
      throw AgentRuntimeError.budgetExceeded("Initial input byte budget exceeded.")
    }
    guard initialInputBytes <= configuration.budget.maxConversationBytes else {
      throw AgentRuntimeError.budgetExceeded("Conversation byte budget exceeded.")
    }

    if let maxOutputTokens = request.options.maxOutputTokens {
      guard maxOutputTokens > 0 else {
        throw AgentRuntimeError.invalidRequest("maxOutputTokens must be positive when supplied.")
      }
    }
    if let temperature = request.options.temperature {
      guard temperature.isFinite else {
        throw AgentRuntimeError.invalidRequest("temperature must be finite when supplied.")
      }
    }
    if let workingDirectory = request.workingDirectory {
      guard
        workingDirectory.isFileURL,
        !workingDirectory.path.isEmpty,
        workingDirectory.path.hasPrefix("/")
      else {
        throw AgentRuntimeError.invalidRequest(
          "workingDirectory must be an absolute file URL."
        )
      }
    }
  }

  func loadModel(for request: AgentRunRequest) async throws -> ModelDescriptor {
    let descriptor = inferenceProvider.descriptor
    guard !descriptor.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AgentRuntimeError.providerFailure(
        "The inference provider has an invalid ID.",
        isRetryable: false
      )
    }

    try Task.checkCancellation()
    let models: [ModelDescriptor]
    do {
      models = try await inferenceProvider.availableModels()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      if Task.isCancelled {
        throw CancellationError()
      }
      throw AgentRuntimeError.providerFailure("Model discovery failed.", isRetryable: true)
    }
    try Task.checkCancellation()

    let matches = models.filter { $0.id == request.modelID }
    guard matches.count <= 1 else {
      throw AgentRuntimeError.providerFailure(
        "Model discovery returned duplicate model IDs.",
        isRetryable: false
      )
    }
    guard let model = matches.first else {
      throw AgentRuntimeError.modelUnavailable(request.modelID)
    }
    guard model.providerID == descriptor.id else {
      throw AgentRuntimeError.providerFailure(
        "The selected model does not belong to the injected provider.",
        isRetryable: false
      )
    }
    return model
  }

  func validate(request: AgentRunRequest, against model: ModelDescriptor) throws {
    if let efforts = model.supportedReasoningEfforts {
      guard Set(efforts).count == efforts.count,
        model.defaultReasoningEffort.map({ efforts.contains($0) }) ?? true
      else {
        throw AgentRuntimeError.providerFailure(
          "The model reported invalid reasoning effort metadata.", isRetryable: false
        )
      }
      if let requestedEffort = request.options.reasoningEffort,
        !efforts.contains(requestedEffort)
      {
        throw AgentRuntimeError.invalidRequest("The selected model does not support that effort.")
      }
    }
    if let contextWindow = model.contextWindow, contextWindow <= 0 {
      throw AgentRuntimeError.providerFailure(
        "The model reported an invalid context window.",
        isRetryable: false
      )
    }
    if let maxOutputTokens = model.maxOutputTokens, maxOutputTokens <= 0 {
      throw AgentRuntimeError.providerFailure(
        "The model reported an invalid output limit.",
        isRetryable: false
      )
    }
    if let requested = request.options.maxOutputTokens,
      let modelMaximum = model.maxOutputTokens,
      requested > modelMaximum
    {
      throw AgentRuntimeError.invalidRequest(
        "Requested output tokens exceed the selected model limit."
      )
    }

    try requireCapability(.textInput, from: model)
    try requireCapability(.streaming, from: model)
    let containsImage = (request.contextMessages + request.initialMessages).contains { message in
      message.content.contains { content in
        if case .image = content {
          return true
        }
        return false
      }
    }
    if containsImage {
      try requireCapability(.imageInput, from: model)
    }
  }

  func validateToolSnapshot(
    _ tools: [ToolDefinition],
    request: AgentRunRequest,
    model: ModelDescriptor
  ) throws {
    try validateToolDefinitions(tools)

    switch request.toolChoice {
    case .none:
      break
    case .automatic:
      if !tools.isEmpty {
        try requireCapability(.toolCalling, from: model)
      }
    case .required:
      guard !tools.isEmpty else {
        throw AgentRuntimeError.invalidRequest("Required tool choice needs at least one tool.")
      }
      try requireCapability(.toolCalling, from: model)
    case .named(let name):
      guard tools.contains(where: { $0.name == name }) else {
        throw AgentRuntimeError.invalidRequest("The named tool is unavailable.")
      }
      try requireCapability(.toolCalling, from: model)
    }
  }

  func validateToolDefinitions(_ tools: [ToolDefinition]) throws {
    guard tools.count <= configuration.budget.maxDiscoveredTools else {
      throw AgentRuntimeError.budgetExceeded("Discovered tool count budget exceeded.")
    }

    var names: Set<String> = []
    for tool in tools {
      guard !tool.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw AgentRuntimeError.protocolViolation("Tool discovery returned an empty name.")
      }
      guard names.insert(tool.name).inserted else {
        throw AgentRuntimeError.protocolViolation("Tool discovery returned duplicate names.")
      }
    }
    let serializedToolBytes: Int
    do {
      serializedToolBytes = try JSONEncoder().encode(tools).count
    } catch {
      throw AgentRuntimeError.protocolViolation(
        "Tool discovery returned a schema that cannot be serialized."
      )
    }
    guard serializedToolBytes <= configuration.budget.maxSerializedToolDefinitionsBytes else {
      throw AgentRuntimeError.budgetExceeded(
        "Serialized tool definition byte budget exceeded."
      )
    }
  }

  func initialToolCallIDs(in messages: [Message]) throws -> Set<ToolCallID> {
    var seenCallIDs: Set<ToolCallID> = []
    var unresolvedCallIDs: Set<ToolCallID> = []
    for message in messages {
      for content in message.content {
        switch content {
        case .toolCall(let call):
          guard message.role == .assistant else {
            throw AgentRuntimeError.invalidRequest(
              "Initial tool calls are only valid in assistant messages."
            )
          }
          guard !call.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentRuntimeError.invalidRequest("Initial tool call IDs cannot be empty.")
          }
          guard !call.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentRuntimeError.invalidRequest("Initial tool call names cannot be empty.")
          }
          guard seenCallIDs.insert(call.id).inserted else {
            throw AgentRuntimeError.invalidRequest("Initial tool call IDs must be unique.")
          }
          unresolvedCallIDs.insert(call.id)
        case .toolResult(let result):
          guard message.role == .tool else {
            throw AgentRuntimeError.invalidRequest(
              "Initial tool results are only valid in tool messages."
            )
          }
          guard
            !result.toolCallID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          else {
            throw AgentRuntimeError.invalidRequest("Initial tool result IDs cannot be empty.")
          }
          guard unresolvedCallIDs.remove(result.toolCallID) != nil else {
            throw AgentRuntimeError.invalidRequest(
              "Each initial tool result must resolve one earlier unresolved call."
            )
          }
        case .text, .image:
          guard message.role != .tool else {
            throw AgentRuntimeError.invalidRequest(
              "Initial tool messages may only contain tool results."
            )
          }
        }
      }
    }
    guard unresolvedCallIDs.isEmpty else {
      throw AgentRuntimeError.invalidRequest(
        "Initial tool calls must be resolved before inference starts."
      )
    }
    return seenCallIDs
  }

  func validateConversationSize(_ messages: [Message]) throws {
    let serializedBytes: Int
    do {
      serializedBytes = try JSONEncoder().encode(messages).count
    } catch {
      throw AgentRuntimeError.invalidState("The conversation could not be serialized.")
    }
    guard serializedBytes <= configuration.budget.maxConversationBytes else {
      throw AgentRuntimeError.budgetExceeded("Conversation byte budget exceeded.")
    }
  }

  func requireCapability(
    _ capability: InferenceCapability,
    from model: ModelDescriptor
  ) throws {
    let providerCapabilities = inferenceProvider.descriptor.capabilities
    guard
      providerCapabilities.contains(capability),
      model.capabilities.contains(capability)
    else {
      throw AgentRuntimeError.unsupportedCapability(capability)
    }
  }
}
