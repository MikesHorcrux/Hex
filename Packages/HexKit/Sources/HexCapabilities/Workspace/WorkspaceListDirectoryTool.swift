import HexCore

public struct WorkspaceListDirectoryTool: HostTool, Sendable {
  public let definition = ToolDefinition(
    name: "workspace_list_directory",
    description:
      "List one directory inside the selected workspace without following symbolic links.",
    inputSchema: HostToolSchema.object(
      properties: [
        "path": HostToolSchema.string(
          "A path relative to the run working directory. Use a single dot for that directory.",
          maximumLength: 4_096
        )
      ],
      required: ["path"]
    )
  )

  private let fileSystem: WorkspaceFileSystem

  public init(fileSystem: WorkspaceFileSystem) {
    self.fileSystem = fileSystem
  }

  public func authorizationRequest(
    for call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> AuthorizationRequest {
    let arguments = try ToolCallArguments(call.arguments, allowedNames: ["path"])
    let path = try arguments.requiredString(named: "path", maximumBytes: 4_096)
    let resource = try await fileSystem.authorizationResource(
      path: path,
      workingDirectory: context.workingDirectory
    )
    return AuthorizationRequest(
      runID: context.runID,
      toolCallID: call.id,
      capability: CapabilityID(rawValue: "workspace.read"),
      operation: "list",
      resource: resource,
      explanation: "Allow Hex to list this workspace directory."
    )
  }

  public func execute(
    _ call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> ToolResult {
    do {
      let arguments = try ToolCallArguments(call.arguments, allowedNames: ["path"])
      let path = try arguments.requiredString(named: "path", maximumBytes: 4_096)
      let entries = try await fileSystem.listDirectory(
        at: path,
        relativeTo: context.workingDirectory
      )
      return WorkspaceToolResult.directory(entries, callID: call.id)
    } catch {
      return try WorkspaceToolResult.failure(error, callID: call.id)
    }
  }
}
