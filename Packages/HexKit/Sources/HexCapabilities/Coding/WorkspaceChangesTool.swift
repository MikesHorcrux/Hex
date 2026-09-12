import HexCore

public struct WorkspaceChangesTool: HostTool {
  public let definition = ToolDefinition(
    name: "workspace_changes",
    description:
      "Review this task's starting Git changes, current staged/unstaged diff, untracked revisions and exact Hex patch receipts. Command-made changes have unknown authorship. This never stages, commits, reverts, or pushes.",
    inputSchema: HostToolSchema.object(
      properties: [
        "before_patch_id": HostToolSchema.string(
          "Page older patch receipts using nextPatchID.", maximumLength: 512)
      ], required: []))
  let manager: CodingWorkspaceManager
  let sessions: ProcessSessionManager
  public init(manager: CodingWorkspaceManager, sessions: ProcessSessionManager) {
    self.manager = manager
    self.sessions = sessions
  }
  public func authorizationRequest(for call: ToolCall, in context: ToolExecutionContext)
    async throws -> AuthorizationRequest
  {
    guard call.name == definition.name else {
      throw WorkspacePatchError.invalidPatch
    }
    let args = try ToolCallArguments(call.arguments, allowedNames: ["before_patch_id"])
    let before = try args.optionalString(named: "before_patch_id", maximumBytes: 512)
    let scope = try await sessions.scope(context)
    _ = before
    return AuthorizationRequest(
      runID: context.runID, toolCallID: call.id, capability: .init(rawValue: "workspace.read"),
      operation: "changes", resource: scope.workspace.path,
      explanation: "Read Git changes and this task's patch receipts.")
  }
  public func execute(_ call: ToolCall, in context: ToolExecutionContext) async throws -> ToolResult
  {
    guard call.name == definition.name else {
      throw WorkspacePatchError.invalidPatch
    }
    let args = try ToolCallArguments(call.arguments, allowedNames: ["before_patch_id"])
    let before = try args.optionalString(named: "before_patch_id", maximumBytes: 512)
    let scope = try await sessions.scope(context)
    return try await ProcessSessionTool.result(
      manager.review(taskID: scope.taskID, before: before), call: call)
  }
}
