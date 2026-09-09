import HexCore

/// Re-observation remains live. Mutating/unknown tools cannot replay an earlier task operation,
/// even when a provider invents a new call ID or context compaction removed the original prose.
actor HexTaskGuardedToolExecutor: ToolExecutor {
  let base: any ToolExecutor
  let effects: (any AgentTaskEffectReading)?
  private var authorizedCapabilities: [AgentRunID: [ToolCallID: CapabilityID]] = [:]

  init(base: any ToolExecutor, effects: (any AgentTaskEffectReading)?) {
    self.base = base
    self.effects = effects
  }

  func finishRun(_ runID: AgentRunID) { authorizedCapabilities.removeValue(forKey: runID) }

  func availableTools() async throws -> [ToolDefinition] { try await base.availableTools() }

  func authorizationRequest(for call: ToolCall, in context: ToolExecutionContext)
    async throws -> AuthorizationRequest
  {
    let request = try await base.authorizationRequest(for: call, in: context)
    guard (authorizedCapabilities[context.runID]?.count ?? 0) < 4_096 else {
      throw AgentTaskStorageError.invalidRecord
    }
    authorizedCapabilities[context.runID, default: [:]][call.id] = request.capability
    return request
  }

  func execute(_ call: ToolCall, in context: ToolExecutionContext) async throws -> ToolResult {
    guard let capability = authorizedCapabilities[context.runID]?.removeValue(forKey: call.id)
    else {
      throw AgentTaskStorageError.invalidRecord
    }
    // Exact host capability allowlist: an untrusted MCP tool cannot opt itself into this set.
    let readCapabilities: Set<String> = [
      "workspace.read", "artifact.read", "process.session.read", "mac.application.read",
      "mac.accessibility.read",
      "network.web.read", "network.web.search", "hex.self.read",
    ]
    // Only the native session manager owns this capability. It independently checks the stable
    // task, known prior process exit and a later committed patch generation before a repeat.
    let nativeSessionStart =
      capability.rawValue == "process.session.execute" && call.name == "process_start"
    if let effects, !readCapabilities.contains(capability.rawValue), !nativeSessionStart,
      let prior = try await effects.previousTaskEffect(
        runID: context.runID,
        fingerprint: AgentTaskOperationFingerprint.data(for: call)),
      prior.result?.notExecutedReason == nil
    {
      return ToolResult(
        toolCallID: call.id, status: .failure,
        output: .object([
          "error": .string("task_operation_already_dispatched"),
          "previous_run_id": .string(prior.runID.rawValue.uuidString),
          "previous_call_id": .string(prior.callID.rawValue),
          "previous_outcome": .string(
            prior.result?.status == .success ? "completed" : "requires_reconciliation"),
          "instruction": .string(
            "This operation was not repeated. Inspect the earlier receipt and current state before continuing."
          ),
        ]), requiresUserAttention: true)
    }
    return try await base.execute(call, in: context)
  }
}
