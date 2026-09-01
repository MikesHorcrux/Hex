import HexCore

public struct WorkspaceReplaceTextTool: HostTool, Sendable {
  public let definition = ToolDefinition(
    name: "workspace_replace_text",
    description:
      "Revision-guardedly replace an exact number of text occurrences in one workspace file.",
    inputSchema: HostToolSchema.object(
      properties: [
        "path": HostToolSchema.string(
          "A file path relative to the run working directory.",
          maximumLength: 4_096
        ),
        "old_text": HostToolSchema.string(
          "The exact nonempty text to replace.",
          maximumLength: 1 * 1_024 * 1_024
        ),
        "new_text": HostToolSchema.string(
          "The replacement text, which may be empty.",
          maximumLength: 1 * 1_024 * 1_024
        ),
        "expected_revision": HostToolSchema.string(
          "The 64-character revision returned by a read.",
          maximumLength: 64
        ),
        "expected_occurrences": HostToolSchema.integer(
          "The exact number of non-overlapping occurrences that must be present.",
          minimum: 1,
          maximum: 10_000
        ),
      ],
      required: [
        "path",
        "old_text",
        "new_text",
        "expected_revision",
        "expected_occurrences",
      ]
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
      operation: "replace_text",
      resource: resource,
      details: [
        "old_text_bytes": .integer(Int64(arguments.oldText.utf8.count)),
        "new_text_bytes": .integer(Int64(arguments.newText.utf8.count)),
        "expected_occurrences": .integer(Int64(arguments.expectedOccurrences)),
      ],
      explanation: "Allow Hex to make a revision-guarded text replacement in this workspace file."
    )
  }

  public func execute(
    _ call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> ToolResult {
    do {
      let arguments = try parsedArguments(call)
      let file = try await fileSystem.replaceText(
        arguments.oldText,
        with: arguments.newText,
        in: arguments.path,
        expectedRevision: arguments.expectedRevision,
        expectedOccurrences: arguments.expectedOccurrences,
        relativeTo: context.workingDirectory
      )
      return WorkspaceToolResult.file(file, callID: call.id, includesContent: false)
    } catch {
      return try WorkspaceToolResult.failure(error, callID: call.id)
    }
  }

  private func parsedArguments(
    _ call: ToolCall
  ) throws -> (
    path: String,
    oldText: String,
    newText: String,
    expectedRevision: String,
    expectedOccurrences: Int
  ) {
    let arguments = try ToolCallArguments(
      call.arguments,
      allowedNames: [
        "path",
        "old_text",
        "new_text",
        "expected_revision",
        "expected_occurrences",
      ]
    )
    let expectedRevision = try arguments.requiredString(
      named: "expected_revision",
      maximumBytes: 64
    )
    guard WorkspaceRevision.isValid(expectedRevision) else {
      throw ToolCallArgumentsError.invalidArguments
    }
    return try (
      path: arguments.requiredString(named: "path", maximumBytes: 4_096),
      oldText: arguments.requiredString(
        named: "old_text",
        maximumBytes: 1 * 1_024 * 1_024
      ),
      newText: arguments.requiredString(
        named: "new_text",
        maximumBytes: 1 * 1_024 * 1_024,
        allowsEmpty: true
      ),
      expectedRevision: expectedRevision,
      expectedOccurrences: arguments.requiredInteger(
        named: "expected_occurrences",
        range: 1...10_000
      )
    )
  }
}
