import HexCore

extension AgentRuntime {
  func execute(
    _ request: AgentRunRequest,
    model: ModelDescriptor
  ) async throws -> AgentRunResult {
    // A caller that explicitly disables tools must not acquire optional dependencies. Keep the
    // snapshot for tool-enabled runs intact, including a named call's no-more-tools continuation.
    let tools = request.toolChoice == .none ? [] : try await discoverTools()
    try validateToolSnapshot(tools, request: request, model: model)

    let prepared = try await inferenceAtBoundary(request.runID) {
      try await self.prepareInitialContext(request, model: model, tools: tools)
    }
    var conversation = prepared.messages
    var turns: [InferenceTurn] = []
    var previousProviderResponseID: String?
    var seenToolCallIDs = try initialToolCallIDs(in: conversation)
    var seenAuthorizationRequestIDs = Set<AuthorizationRequestID>()
    var totalToolCalls = 0
    var totalToolResultBytes = 0
    var totalReportedTokens: UInt64 = prepared.reportedTokens
    var effectiveToolChoice = request.toolChoice
    let allowsParallelToolCalls =
      inferenceProvider.descriptor.capabilities.contains(.parallelToolCalling)
      && model.capabilities.contains(.parallelToolCalling)

    while true {
      try checkBoundaryStop(request.runID)
      guard totalReportedTokens < configuration.budget.maxReportedTokens else {
        throw AgentRuntimeError.budgetExceeded(
          "Reported token budget exhausted before the next inference request.")
      }
      guard turns.count < configuration.budget.maxTurns else {
        throw AgentRuntimeError.budgetExceeded("Inference turn budget exceeded.")
      }
      try validateConversationSize(conversation)
      if !turns.isEmpty {
        let compacted = try await inferenceAtBoundary(request.runID) {
          [conversation, totalReportedTokens] in
          try await self.prepareActiveContext(
            conversation, protectedCount: prepared.messages.count, request: request,
            model: model, tools: tools,
            remainingReportedTokens: self.configuration.budget.maxReportedTokens
              - totalReportedTokens)
        }
        if let compacted {
          conversation = compacted.messages
          totalReportedTokens = try addReportedTokens(
            compacted.reportedTokens, to: totalReportedTokens)
          previousProviderResponseID = nil
          guard totalReportedTokens < configuration.budget.maxReportedTokens else {
            throw AgentRuntimeError.budgetExceeded(
              "Summary consumed the remaining reported token budget.")
          }
        }
      }
      let allowedToolNames: Set<String>
      switch effectiveToolChoice {
      case .none:
        allowedToolNames = []
      case .named(let name):
        allowedToolNames = [name]
      case .automatic, .required:
        allowedToolNames = Set(tools.map(\.name))
      }

      let inferenceRequest = InferenceRequest(
        providerID: inferenceProvider.descriptor.id,
        modelID: request.modelID,
        previousProviderResponseID: previousProviderResponseID,
        messages: conversation,
        tools: tools,
        toolChoice: effectiveToolChoice,
        options: request.options
      )
      try await append(.inferenceRequested(inferenceRequest), to: request.runID)
      try Task.checkCancellation()

      let initialAccumulator = InferenceTurnAccumulator(
        budget: configuration.budget,
        allowedToolNames: allowedToolNames,
        priorToolCallIDs: seenToolCallIDs,
        remainingToolCalls: configuration.budget.maxToolCalls - totalToolCalls,
        remainingReportedTokens: configuration.budget.maxReportedTokens - totalReportedTokens,
        allowsParallelToolCalls: allowsParallelToolCalls
      )
      var accumulator = try await inferenceAtBoundary(request.runID) {
        let stream: InferenceStream
        do {
          stream = try await self.inferenceProvider.stream(inferenceRequest)
        } catch is CancellationError {
          throw CancellationError()
        } catch let error as any InferenceProviderFailure {
          throw AgentRuntimeError.providerFailure(
            error.userFacingMessage,
            isRetryable: error.isRetryable
          )
        } catch {
          if Task.isCancelled {
            throw CancellationError()
          }
          throw AgentRuntimeError.providerFailure(
            "The inference provider failed to open a stream.",
            isRetryable: true
          )
        }

        return try await stream.consume { cursor in
          var accumulator = initialAccumulator
          while true {
            let event: InferenceStreamEvent?
            do {
              event = try await cursor.next()
            } catch is CancellationError {
              throw CancellationError()
            } catch let error as any InferenceProviderFailure {
              throw AgentRuntimeError.providerFailure(
                error.userFacingMessage,
                isRetryable: error.isRetryable
              )
            } catch {
              if Task.isCancelled {
                throw CancellationError()
              }
              throw AgentRuntimeError.providerFailure(
                "The inference stream failed.",
                isRetryable: true
              )
            }
            guard let event else {
              break
            }
            var candidateAccumulator = accumulator
            try candidateAccumulator.accept(event)
            try await self.append(.inferenceEvent(event), to: request.runID)
            accumulator = candidateAccumulator
            try Task.checkCancellation()
          }
          try Task.checkCancellation()
          return accumulator
        }

      }

      let output = try accumulator.finish()
      previousProviderResponseID = output.providerResponseID
      switch effectiveToolChoice {
      case .required, .named:
        guard output.stopReason == .toolCalls else {
          throw AgentRuntimeError.protocolViolation(
            "The inference provider did not honor the required tool choice."
          )
        }
      case .automatic, .none:
        break
      }
      totalReportedTokens = try addReportedTokens(
        output.reportedTokens,
        to: totalReportedTokens
      )
      var conversationWithAssistant = conversation
      conversationWithAssistant.append(output.assistantMessage)
      try validateConversationSize(conversationWithAssistant)
      try await append(.messageAppended(output.assistantMessage), to: request.runID)
      try recordAnnouncedToolCalls(output.toolCalls, for: request.runID)
      conversation = conversationWithAssistant

      switch output.stopReason {
      case .stop:
        turns.append(
          InferenceTurn(
            number: turns.count + 1,
            requestID: inferenceRequest.id,
            providerResponseID: output.providerResponseID,
            assistantMessage: output.assistantMessage,
            toolResults: [],
            usage: output.usage,
            stopReason: output.stopReason
          )
        )
        try await append(.runCompleted, to: request.runID)
        return AgentRunResult(
          runID: request.runID,
          messages: conversation,
          turns: turns,
          toolCallCount: totalToolCalls,
          totalReportedTokens: totalReportedTokens
        )

      case .toolCalls:
        if output.toolCalls.count > 1 {
          try requireCapability(.parallelToolCalling, from: model)
        }
        totalToolCalls = try addToolCalls(output.toolCalls.count, to: totalToolCalls)
        if effectiveToolChoice == .required {
          effectiveToolChoice = .automatic
        } else if case .named = effectiveToolChoice {
          effectiveToolChoice = .none
        }
        for call in output.toolCalls {
          seenToolCallIDs.insert(call.id)
        }
        try checkBoundaryStop(request.runID)
        let toolOutput = try await processToolBatch(
          output.toolCalls,
          runID: request.runID,
          workingDirectory: request.workingDirectory,
          priorConversation: conversation,
          priorSerializedToolResultBytes: totalToolResultBytes,
          seenAuthorizationRequestIDs: &seenAuthorizationRequestIDs
        )
        totalToolResultBytes = toolOutput.totalSerializedToolResultBytes
        conversation.append(contentsOf: toolOutput.messages)
        turns.append(
          InferenceTurn(
            number: turns.count + 1,
            requestID: inferenceRequest.id,
            providerResponseID: output.providerResponseID,
            assistantMessage: output.assistantMessage,
            toolResults: toolOutput.results,
            usage: output.usage,
            stopReason: output.stopReason
          )
        )

      case .length, .contentFilter, .other:
        throw AgentRuntimeError.protocolViolation(
          "The inference provider returned a non-success terminal stop reason."
        )
      }
    }
  }

  private func addToolCalls(_ count: Int, to current: Int) throws -> Int {
    let (total, overflow) = current.addingReportingOverflow(count)
    guard !overflow, total <= configuration.budget.maxToolCalls else {
      throw AgentRuntimeError.budgetExceeded("Tool call budget exceeded.")
    }
    return total
  }

  private func addReportedTokens(_ count: UInt64, to current: UInt64) throws -> UInt64 {
    let (total, overflow) = current.addingReportingOverflow(count)
    guard !overflow, total <= configuration.budget.maxReportedTokens else {
      throw AgentRuntimeError.budgetExceeded("Reported token budget exceeded.")
    }
    return total
  }
}
