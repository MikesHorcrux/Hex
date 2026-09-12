import HexCore

public struct WorkspaceSearchTextTool: HostTool, Sendable {
  public let definition = ToolDefinition(
    name: "workspace_search_text",
    description:
      "Search bounded UTF-8 workspace files for an exact single-line text fragment. Oversized files are skipped and counted in skipped_oversized_files; such results are not an exhaustive search of those files.",
    inputSchema: HostToolSchema.object(
      properties: [
        "path": HostToolSchema.string(
          "A directory path relative to the run working directory.",
          maximumLength: 4_096
        ),
        "query": HostToolSchema.string(
          "The exact single-line text fragment to find.",
          maximumLength: 4_096
        ),
      ],
      required: ["path", "query"]
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
    let arguments = try ToolCallArguments(call.arguments, allowedNames: ["path", "query"])
    let path = try arguments.requiredString(named: "path", maximumBytes: 4_096)
    let query = try arguments.requiredString(named: "query", maximumBytes: 4_096)
    let resource = try await fileSystem.authorizationResource(
      path: path,
      workingDirectory: context.workingDirectory
    )
    return AuthorizationRequest(
      runID: context.runID,
      toolCallID: call.id,
      capability: CapabilityID(rawValue: "workspace.read"),
      operation: "search",
      resource: resource,
      details: ["query_bytes": .integer(Int64(query.utf8.count))],
      explanation: "Allow Hex to search text under this workspace directory."
    )
  }

  public func execute(
    _ call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> ToolResult {
    do {
      let arguments = try ToolCallArguments(call.arguments, allowedNames: ["path", "query"])
      let path = try arguments.requiredString(named: "path", maximumBytes: 4_096)
      let query = try arguments.requiredString(named: "query", maximumBytes: 4_096)
      let report = try await fileSystem.searchTextReport(
        query,
        under: path,
        relativeTo: context.workingDirectory
      )
      return WorkspaceToolResult.search(report, callID: call.id)
    } catch {
      return try WorkspaceToolResult.failure(error, callID: call.id)
    }
  }
}
