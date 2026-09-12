import HexCore

public struct ArtifactToolExecutor: ToolExecutor, Sendable {
  private let executor: HostToolExecutor

  public init(reader: any ArtifactReading) throws {
    executor = try HostToolExecutor(tools: [
      ArtifactListTool(), ArtifactReadTool(reader: reader), ArtifactSearchTool(reader: reader),
    ])
  }

  public func availableTools() async throws -> [ToolDefinition] {
    try await executor.availableTools()
  }

  public func authorizationRequest(for call: ToolCall, in context: ToolExecutionContext)
    async throws
    -> AuthorizationRequest
  {
    try await executor.authorizationRequest(for: call, in: context)
  }

  public func execute(_ call: ToolCall, in context: ToolExecutionContext) async throws -> ToolResult
  {
    try await executor.execute(call, in: context)
  }
}
