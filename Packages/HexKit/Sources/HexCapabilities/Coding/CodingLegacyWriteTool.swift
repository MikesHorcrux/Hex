import HexCore

/// Retains the existing tool schemas and guarded file implementation while recording provenance.
struct CodingLegacyWriteTool: HostTool {
  let base: any HostTool
  let manager: CodingWorkspaceManager
  let sessions: ProcessSessionManager
  private let calls = ToolAuthorizationLedger(maximumEntries: 8)
  var definition: ToolDefinition { base.definition }
  init(base: any HostTool, manager: CodingWorkspaceManager, sessions: ProcessSessionManager) {
    self.base = base
    self.manager = manager
    self.sessions = sessions
  }
  func authorizationRequest(for call: ToolCall, in context: ToolExecutionContext) async throws
    -> AuthorizationRequest
  {
    _ = try await sessions.scope(context)
    let request = try await base.authorizationRequest(for: call, in: context)
    try await calls.record(call: call, runID: context.runID)
    return request
  }
  func execute(_ call: ToolCall, in context: ToolExecutionContext) async throws -> ToolResult {
    try await calls.take(call: call, runID: context.runID)
    do {
      return try await manager.executeLegacy(
        base, call: call, context: context, scope: sessions.scope(context))
    } catch {
      // Preserve the ordinary workspace tool's known rejection receipts for preflight
      // failures. Outcome-uncertain and unrecognized errors still throw through this mapper.
      return try WorkspaceToolResult.failure(error, callID: call.id)
    }
  }
}
