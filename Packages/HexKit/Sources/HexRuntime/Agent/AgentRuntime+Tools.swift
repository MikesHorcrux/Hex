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
      let context = ToolExecutionContext(
        runID: runID, workingDirectory: workingDirectory, artifacts: runArtifacts[runID] ?? [])
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
      let message: Message
      switch decision {
      case .allow:
        try recordToolStartAttempt(call.id, for: runID)
        runsWithStartedTools.insert(runID)
        try await append(.toolStarted(call), to: runID)
        try Task.checkCancellation()
        let executedResult: ToolResult
        do {
          executedResult = try await toolExecutor.execute(call, in: context)
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

        guard executedResult.toolCallID == call.id else {
          throw AgentRuntimeError.toolExecutionFailure(
            "Tool execution returned a mismatched call ID; its outcome is uncertain."
          )
        }
        guard executedResult.notExecutedReason == nil else {
          throw AgentRuntimeError.toolExecutionFailure(
            "A dispatched tool returned a host-only nonexecution claim; its outcome is uncertain."
          )
        }
        result = try await persistLargeToolOutput(executedResult, runID: runID)
        // A returned outcome belongs in durable history even when cancellation, artifact capacity,
        // or a subsequent inference budget prevents this run from continuing. Persist both forms
        // exactly once so a future conversation never sees this known tool call as unresolved.
        message = try await persistKnownToolReceipt(result, for: runID)
        try Task.checkCancellation()
        do {
          try rememberArtifacts(result.artifacts, for: runID)
        } catch {
          throw AgentRuntimeError.toolExecutionFailure(
            "Hex saved the tool result and its output references, but this run's preserved-output inventory cannot accept them because its capacity was exceeded or a reference conflicts. No references were discarded. Inspect the saved result before continuing; Hex will not repeat the action automatically."
          )
        }
        if result.requiresUserAttention {
          throw AgentRuntimeError.toolExecutionFailure(
            userAttentionMessage(for: result)
          )
        }
        let resultByteCount = try serializedToolResultByteCount(result)
        totalSerializedToolResultBytes = try addingToolResultBytes(
          resultByteCount,
          to: totalSerializedToolResultBytes
        )

      case .deny(let reason):
        result = deniedToolResult(for: call, reason: reason)
        _ = try serializedToolResultByteCount(result)
        message = try await persistKnownToolReceipt(result, for: runID)
        try Task.checkCancellation()
      }

      var conversationWithResult = admittedConversation
      conversationWithResult.append(message)
      try validateConversationSize(conversationWithResult)
      admittedConversation = conversationWithResult
      results.append(result)
      messages.append(message)
    }

    return (results, messages, totalSerializedToolResultBytes)
  }

  private func userAttentionMessage(for result: ToolResult) -> String {
    if case .object(let output) = result.output {
      switch output["error"] {
      case .string("mac_session_locked"):
        return
          "The Mac session is locked. Unlock the Mac, inspect the target app, then start a new request. No action was dispatched and this run will not retry automatically."
      case .string("mac_session_unavailable"):
        return
          "Hex cannot verify an available console session. Return to your logged-in Mac desktop and inspect the target app before starting a new request. No action was dispatched."
      case .string("accessibility_action_outcome_unknown"),
        .string("browser_action_outcome_uncertain"), .string("native_action_outcome_uncertain"):
        return
          "The action may have reached its target, but its outcome is uncertain. Inspect the current app or page and the saved tool receipt before deciding whether another action is needed. Hex stopped and will not repeat the action automatically."
      case .string("accessibility_permission_required"):
        return
          "macOS Accessibility access is missing or was revoked. Open Hex Settings → Mac access, verify Hex Agent’s Accessibility permission, then start a new request. This run stopped and will not retry automatically."
      case .string("file_access_denied"):
        return
          "macOS or filesystem permissions denied access to the requested file or folder. Check Hex Settings → Mac access and the target’s folder permissions. Full access in Hex cannot override macOS. This run stopped and will not retry automatically."
      case .string("screen_permissions_required"):
        return
          "Screen control’s Accessibility or Screen Recording permission is missing or was revoked. Open Hex Settings → Mac access, allow the missing permission for the screen helper, then verify again. No screen action was dispatched; this run will not retry automatically."
      case .string("screen_permissions_unverified"):
        return
          "Hex could not verify the screen helper’s Mac permissions. Open Hex Settings → Mac access and verify or repair screen control. No screen action was dispatched; this run will not retry automatically."
      default: break
      }
    }
    return
      "Hex stopped because preserving this tool’s output requires your attention. The command may already have changed files or external state. Inspect the saved result and partial output before deciding what to do next; Hex will not repeat it automatically."
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
      output: .object(output),
      notExecutedReason: .authorizationDenied
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
