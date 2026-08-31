import Foundation
import HexCore

extension AgentRuntime {
  func discoverTools() async throws -> [ToolDefinition] {
    try Task.checkCancellation()
    do {
      let tools = try await toolExecutor.availableTools()
      try Task.checkCancellation()
      return tools
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      if Task.isCancelled {
        throw CancellationError()
      }
      throw AgentRuntimeError.toolExecutionFailure("Tool discovery failed.")
    }
  }

  func processToolBatch(
    _ calls: [ToolCall],
    runID: AgentRunID,
    workingDirectory: URL?,
    priorConversation: [Message],
    priorSerializedToolResultBytes: Int,
    seenAuthorizationRequestIDs: inout Set<AuthorizationRequestID>
  ) async throws -> (
    results: [ToolResult],
    messages: [Message],
    totalSerializedToolResultBytes: Int
  ) {
    var authorizationRequests: [AuthorizationRequest] = []
    var executionContexts: [ToolExecutionContext] = []
    authorizationRequests.reserveCapacity(calls.count)
    executionContexts.reserveCapacity(calls.count)

    for call in calls {
      let context = ToolExecutionContext(runID: runID, workingDirectory: workingDirectory)
      let request: AuthorizationRequest
      do {
        request = try await toolExecutor.authorizationRequest(for: call, in: context)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        if Task.isCancelled {
          throw CancellationError()
        }
        throw AgentRuntimeError.authorizationFailure(
          "The tool could not describe its authorization requirements."
        )
      }
      try Task.checkCancellation()
      guard
        request.runID == runID,
        request.toolCallID == call.id,
        seenAuthorizationRequestIDs.insert(request.id).inserted
      else {
        throw AgentRuntimeError.authorizationFailure(
          "The tool returned an invalid authorization correlation."
        )
      }
      try await append(.authorizationRequested(request), to: runID)
      authorizationRequests.append(request)
      executionContexts.append(context)
    }

    var decisions: [AuthorizationDecision] = []
    decisions.reserveCapacity(calls.count)
    var reservedDeniedResultBytes = priorSerializedToolResultBytes

    for (call, request) in zip(calls, authorizationRequests) {
      let decision: AuthorizationDecision
      do {
        decision = try await authorizationProvider.authorize(request)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        if Task.isCancelled {
          throw CancellationError()
        }
        throw AgentRuntimeError.authorizationFailure("Authorization provider failed.")
      }
      try Task.checkCancellation()
      if case .deny(let reason) = decision {
        let resultByteCount = try serializedToolResultByteCount(
          deniedToolResult(for: call, reason: reason)
        )
        reservedDeniedResultBytes = try addingToolResultBytes(
          resultByteCount,
          to: reservedDeniedResultBytes
        )
      }
      try await append(
        .authorizationDecided(requestID: request.id, decision: decision),
        to: runID
      )
      decisions.append(decision)
    }

    var results: [ToolResult] = []
    var messages: [Message] = []
    var admittedConversation = priorConversation
    var totalSerializedToolResultBytes = reservedDeniedResultBytes
    results.reserveCapacity(calls.count)
    messages.reserveCapacity(calls.count)

    for index in calls.indices {
      let call = calls[index]
      let decision = decisions[index]
      let context = executionContexts[index]
      let result: ToolResult
      switch decision {
      case .allow:
        try await append(.toolStarted(call), to: runID)
        runsWithStartedTools.insert(runID)
        try Task.checkCancellation()
        do {
          result = try await toolExecutor.execute(call, in: context)
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          if Task.isCancelled {
            throw CancellationError()
          }
          throw AgentRuntimeError.toolExecutionFailure(
            "Tool execution failed after it started; its outcome is uncertain."
          )
        }

        guard result.toolCallID == call.id else {
          throw AgentRuntimeError.toolExecutionFailure(
            "Tool execution returned a mismatched call ID; its outcome is uncertain."
          )
        }
        let resultByteCount = try serializedToolResultByteCount(result)
        try await appendKnownOutcome(.toolFinished(result), to: runID)
        try Task.checkCancellation()
        totalSerializedToolResultBytes = try addingToolResultBytes(
          resultByteCount,
          to: totalSerializedToolResultBytes
        )

      case .deny(let reason):
        result = deniedToolResult(for: call, reason: reason)
        _ = try serializedToolResultByteCount(result)
      }

      let message = Message(role: .tool, content: [.toolResult(result)])
      var conversationWithResult = admittedConversation
      conversationWithResult.append(message)
      try validateConversationSize(conversationWithResult)
      if case .deny = decision {
        try await append(.toolFinished(result), to: runID)
      }
      try await append(.messageAppended(message), to: runID)
      admittedConversation = conversationWithResult
      results.append(result)
      messages.append(message)
    }

    return (results, messages, totalSerializedToolResultBytes)
  }

  private func deniedToolResult(for call: ToolCall, reason: String?) -> ToolResult {
    var output: [String: JSONValue] = [
      "error": .string("authorization_denied")
    ]
    if let reason, !reason.isEmpty {
      output["reason"] = .string(reason)
    }
    return ToolResult(
      toolCallID: call.id,
      status: .failure,
      output: .object(output)
    )
  }

  private func serializedToolResultByteCount(_ result: ToolResult) throws -> Int {
    let byteCount: Int
    do {
      byteCount = try JSONEncoder().encode(result).count
    } catch {
      throw AgentRuntimeError.toolExecutionFailure(
        "A tool result could not be serialized; an executed outcome must not be retried."
      )
    }
    guard byteCount <= configuration.budget.maxToolResultBytes else {
      throw AgentRuntimeError.budgetExceeded("Per-tool result byte budget exceeded.")
    }
    return byteCount
  }

  private func addingToolResultBytes(_ count: Int, to current: Int) throws -> Int {
    let (total, overflow) = current.addingReportingOverflow(count)
    guard !overflow, total <= configuration.budget.maxTotalToolResultBytes else {
      throw AgentRuntimeError.budgetExceeded("Cumulative tool result byte budget exceeded.")
    }
    return total
  }
}
