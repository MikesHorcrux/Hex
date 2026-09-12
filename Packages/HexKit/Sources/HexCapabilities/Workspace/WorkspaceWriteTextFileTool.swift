import HexCore

public struct WorkspaceWriteTextFileTool: HostTool, Sendable {
  public let definition = ToolDefinition(
    name: "workspace_write_text_file",
    description:
      "Create or revision-guardedly replace one UTF-8 workspace file. "
      + "The parent directory must already exist; create missing directories first.",
    inputSchema: HostToolSchema.object(
      properties: [
        "path": HostToolSchema.string(
          "A file path relative to the run working directory.",
          maximumLength: 4_096
        ),
        "content": HostToolSchema.string(
          "The complete UTF-8 file content.",
          maximumLength: 16 * 1_024 * 1_024
        ),
        "expected_revision": HostToolSchema.string(
          "The 64-character revision returned by a read. Omit only when creating a new file.",
          maximumLength: 64
        ),
      ],
      required: ["path", "content"]
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
    let arguments = try parsedArguments(call)
    let resource = try await fileSystem.authorizationResource(
      path: arguments.path,
      workingDirectory: context.workingDirectory
    )
    return AuthorizationRequest(
      runID: context.runID,
      toolCallID: call.id,
      capability: CapabilityID(rawValue: "workspace.write"),
      operation: arguments.expectedRevision == nil ? "create" : "overwrite",
      resource: resource,
      details: ["content_bytes": .integer(Int64(arguments.content.utf8.count))],
      explanation: "Allow Hex to write this workspace text file."
    )
  }

  public func execute(
    _ call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> ToolResult {
    do {
      let arguments = try parsedArguments(call)
      let file = try await fileSystem.writeTextFile(
        arguments.content,
        at: arguments.path,
        expectedRevision: arguments.expectedRevision,
        relativeTo: context.workingDirectory
      )
      return WorkspaceToolResult.file(file, callID: call.id, includesContent: false)
    } catch {
      return try WorkspaceToolResult.failure(error, callID: call.id)
    }
  }

  private func parsedArguments(
    _ call: ToolCall
  ) throws -> (path: String, content: String, expectedRevision: String?) {
    let arguments = try ToolCallArguments(
      call.arguments,
      allowedNames: ["path", "content", "expected_revision"]
    )
    let expectedRevision = try arguments.optionalString(
      named: "expected_revision",
      maximumBytes: 64
    )
    guard expectedRevision.map(WorkspaceRevision.isValid) ?? true else {
      throw ToolCallArgumentsError.invalidArguments
    }
    return try (
      path: arguments.requiredString(named: "path", maximumBytes: 4_096),
      content: arguments.requiredString(
        named: "content",
        maximumBytes: 16 * 1_024 * 1_024,
        allowsEmpty: true
      ),
      expectedRevision: expectedRevision
    )
  }
}
