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
    priorSerializedToolResultBytes: Int
  ) async throws -> (
    results: [ToolResult],
    messages: [Message],
    totalSerializedToolResultBytes: Int
  ) {
    var decisions: [AuthorizationDecision] = []
    decisions.reserveCapacity(calls.count)
    var reservedDeniedResultBytes = priorSerializedToolResultBytes

    for call in calls {
      let request = AuthorizationRequest(
        runID: runID,
        toolCallID: call.id,
        capability: CapabilityID(rawValue: "tool.\(call.name)"),
        operation: "execute",
        details: [:],
        explanation: "Authorize execution of the requested tool."
      )
      try await append(.authorizationRequested(request), to: runID)
      try Task.checkCancellation()

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

    for (call, decision) in zip(calls, decisions) {
      let result: ToolResult
      switch decision {
      case .allow:
        try await append(.toolStarted(call), to: runID)
        runsWithStartedTools.insert(runID)
        try Task.checkCancellation()
        do {
          result = try await toolExecutor.execute(
            call,
            in: ToolExecutionContext(runID: runID, workingDirectory: workingDirectory)
          )
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
