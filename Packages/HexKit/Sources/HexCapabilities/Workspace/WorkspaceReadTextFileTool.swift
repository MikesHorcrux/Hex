import HexCore

public struct WorkspaceReadTextFileTool: HostTool, Sendable {
  public let definition = ToolDefinition(
    name: "workspace_read_text_file",
    description:
      "Read one bounded UTF-8 file inside the selected workspace and return its revision.",
    inputSchema: WorkspaceToolSchema.object(
      properties: [
        "path": WorkspaceToolSchema.string(
          "A file path relative to the run working directory.",
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
      operation: "read",
      resource: resource,
      explanation: "Allow Hex to read this workspace text file."
    )
  }

  public func execute(
    _ call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> ToolResult {
    do {
      let arguments = try ToolCallArguments(call.arguments, allowedNames: ["path"])
      let path = try arguments.requiredString(named: "path", maximumBytes: 4_096)
      let file = try await fileSystem.readTextFile(
        at: path,
        relativeTo: context.workingDirectory
      )
      return WorkspaceToolResult.file(file, callID: call.id, includesContent: true)
    } catch {
      return try WorkspaceToolResult.failure(error, callID: call.id)
    }
  }
}
