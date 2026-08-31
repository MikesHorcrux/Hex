import HexCore

public struct WorkspaceCodingToolExecutor: ToolExecutor, Sendable {
  private let executor: HostToolExecutor

  public init(fileSystem: WorkspaceFileSystem) throws {
    executor = try HostToolExecutor(tools: [
      WorkspaceListDirectoryTool(fileSystem: fileSystem),
      WorkspaceReadTextFileTool(fileSystem: fileSystem),
      WorkspaceReplaceTextTool(fileSystem: fileSystem),
      WorkspaceSearchTextTool(fileSystem: fileSystem),
      WorkspaceWriteTextFileTool(fileSystem: fileSystem),
    ])
  }

  public init(
    fileSystem: WorkspaceFileSystem,
    processExecutor: any ProcessExecuting,
    processConfiguration: ProcessExecutionConfiguration = .standard,
    /// Host-selected environment for the optional process tool.
    processEnvironment: [String: String]? = nil
  ) throws {
    executor = try HostToolExecutor(tools: [
      ProcessRunTool(
        executor: processExecutor,
        configuration: processConfiguration,
        environment: processEnvironment
      ),
      WorkspaceListDirectoryTool(fileSystem: fileSystem),
      WorkspaceReadTextFileTool(fileSystem: fileSystem),
      WorkspaceReplaceTextTool(fileSystem: fileSystem),
      WorkspaceSearchTextTool(fileSystem: fileSystem),
      WorkspaceWriteTextFileTool(fileSystem: fileSystem),
    ])
  }

  public func availableTools() async throws -> [ToolDefinition] {
    try await executor.availableTools()
  }

  public func authorizationRequest(
    for call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> AuthorizationRequest {
    try await executor.authorizationRequest(for: call, in: context)
  }

  public func execute(
    _ call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> ToolResult {
    try await executor.execute(call, in: context)
  }
}
