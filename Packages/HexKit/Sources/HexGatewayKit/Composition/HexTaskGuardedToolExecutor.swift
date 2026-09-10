import HexCore

/// Re-observation and native presentation remain live. Mutating/unknown tools cannot replay
/// an earlier task operation,
/// even when a provider invents a new call ID or context compaction removed the original prose.
actor HexTaskGuardedToolExecutor: ToolExecutor {
  let base: any ToolExecutor
  let effects: (any AgentTaskEffectReading)?
  private var authorizedOperations:
    [AgentRunID: [ToolCallID: (capability: CapabilityID, operation: String)]] = [:]

  init(base: any ToolExecutor, effects: (any AgentTaskEffectReading)?) {
    self.base = base
    self.effects = effects
  }

  func finishRun(_ runID: AgentRunID) { authorizedOperations.removeValue(forKey: runID) }

  func availableTools() async throws -> [ToolDefinition] { try await base.availableTools() }

  func authorizationRequest(for call: ToolCall, in context: ToolExecutionContext)
    async throws -> AuthorizationRequest
  {
    let request = try await base.authorizationRequest(for: call, in: context)
    guard (authorizedOperations[context.runID]?.count ?? 0) < 4_096 else {
      throw AgentTaskStorageError.invalidRecord
    }
    authorizedOperations[context.runID, default: [:]][call.id] = (
      request.capability, request.operation
    )
    return request
  }

  func execute(_ call: ToolCall, in context: ToolExecutionContext) async throws -> ToolResult {
    guard let authorized = authorizedOperations[context.runID]?.removeValue(forKey: call.id)
    else {
      throw AgentTaskStorageError.invalidRecord
    }
    let capability = authorized.capability
    // Exact host capability allowlist: an untrusted MCP tool cannot opt itself into this set.
    let readCapabilities: Set<String> = [
      "workspace.read", "artifact.read", "process.session.read", "mac.application.read",
      "mac.accessibility.read", "browser.session.observe",
      "network.web.read", "network.web.search", "hex.self.read",
    ]
    // Only the native session manager owns this capability. It independently checks the stable
    // task, known prior process exit and a later committed patch generation before a repeat.
    let nativeSessionStart =
      capability.rawValue == "process.session.execute" && call.name == "process_start"
    // Native patches preflight every existing file's revision and every created destination.
    // Their manager owns partial receipts and requires reconciliation after uncertain writes.
    // The generic fingerprint fence would prevent correcting/retrying a rejected preflight.
    let nativeRevisionCheckedPatch =
      capability.rawValue == "workspace.write" && call.name == "workspace_apply_patch"
    // App focus and local preview presentation can become obsolete when a user changes tabs or
    // apps. Fresh, individually authorized requests must remain usable in later attempts. These
    // exact native tools retain their target/URL validation and return any new uncertainty intact;
    // arbitrary accessibility actions and MCP tools do not receive this exception.
    let nativePresentation =
      capability.rawValue == "mac.application.control"
      && ((call.name == "mac_activate_application"
        && authorized.operation == "activate-application")
        || (call.name == "mac_open_local_url" && authorized.operation == "open-local-preview"))
    if let effects, !readCapabilities.contains(capability.rawValue), !nativeSessionStart,
      !nativeRevisionCheckedPatch, !nativePresentation,
      let prior = try await effects.previousTaskEffect(
        runID: context.runID,
        fingerprint: AgentTaskOperationFingerprint.data(for: call)),
      prior.result?.notExecutedReason == nil
    {
      let completed =
        prior.result?.status == .success && prior.result?.requiresUserAttention == false
      return ToolResult(
        toolCallID: call.id, status: .failure,
        output: .object([
          "error": .string("task_operation_already_dispatched"),
          "dispatched": .boolean(false),
          "previous_run_id": .string(prior.runID.rawValue.uuidString),
          "previous_call_id": .string(prior.callID.rawValue),
          "previous_outcome": .string(
            completed ? "completed" : "requires_reconciliation"),
          "instruction": .string(
            completed
              ? "This call was not dispatched because an earlier attempt completed the same operation. Inspect the earlier receipt and current state, then continue with the remaining work."
              : "This operation was not repeated. Inspect the earlier receipt and current state before continuing."
          ),
        ]), requiresUserAttention: !completed,
        executionOutcome: completed ? .completed : nil)
    }
    return try await base.execute(call, in: context)
  }
}
