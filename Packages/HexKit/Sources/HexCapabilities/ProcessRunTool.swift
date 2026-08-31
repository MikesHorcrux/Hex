import CryptoKit
import Foundation
import HexCore

public struct ProcessRunTool: HostTool, Sendable {
  public let definition: ToolDefinition

  private let executor: any ProcessExecuting
  private let configuration: ProcessExecutionConfiguration
  /// Keeps exact-invocation grants stable only for this tool lifetime without persisting a
  /// guessable digest of possibly sensitive arguments.
  private let authorizationKey: SymmetricKey

  public init(
    executor: any ProcessExecuting,
    configuration: ProcessExecutionConfiguration = .standard
  ) {
    definition = ToolDefinition(
      name: "process_run",
      description:
        "Run one non-interactive local executable with bounded combined output and no implicit shell.",
      inputSchema: WorkspaceToolSchema.object(
        properties: [
          "executable": WorkspaceToolSchema.string(
            "An absolute executable path. A shell is used only when explicitly selected here.",
            maximumLength: 4_096
          ),
          "arguments": WorkspaceToolSchema.stringArray(
            "The exact argument vector passed to the executable.",
            maximumItems: configuration.maximumArguments,
            maximumItemLength: configuration.maximumArgumentBytes
          ),
          "timeout_seconds": WorkspaceToolSchema.integer(
            "The maximum non-interactive execution time.",
            minimum: 1,
            maximum: configuration.maximumTimeoutSeconds
          ),
        ],
        required: ["executable", "arguments"]
      )
    )
    self.executor = executor
    self.configuration = configuration
    authorizationKey = SymmetricKey(size: .bits256)
  }

  public func authorizationRequest(
    for call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> AuthorizationRequest {
    let request = try validatedRequest(for: call, in: context)
    let argumentBytes = request.arguments.reduce(into: 0) { total, argument in
      total += argument.utf8.count
    }
    return AuthorizationRequest(
      runID: context.runID,
      toolCallID: call.id,
      capability: CapabilityID(rawValue: "process.execute"),
      operation: "run",
      resource: ProcessAuthorizationResource.resource(
        for: request,
        key: authorizationKey
      ),
      details: [
        "executable": .string(request.executable.path),
        "working_directory": .string(request.workingDirectory.path),
        "argument_count": .integer(Int64(request.arguments.count)),
        "argument_bytes": .integer(Int64(argumentBytes)),
        "timeout_seconds": .integer(Int64(request.timeoutSeconds)),
      ],
      explanation: "Allow Hex to run this exact local process invocation."
    )
  }

  public func execute(
    _ call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> ToolResult {
    do {
      let request = try validatedRequest(for: call, in: context)
      let result = try await executor.execute(request)
      return ProcessToolResult.result(result, callID: call.id)
    } catch {
      return try ProcessToolResult.failure(error, callID: call.id)
    }
  }

  private func validatedRequest(
    for call: ToolCall,
    in context: ToolExecutionContext
  ) throws -> ProcessExecutionRequest {
    guard call.name == definition.name, let workingDirectory = context.workingDirectory else {
      throw ToolCallArgumentsError.invalidArguments
    }
    let arguments = try ToolCallArguments(
      call.arguments,
      allowedNames: ["executable", "arguments", "timeout_seconds"]
    )
    let executablePath = try arguments.requiredString(
      named: "executable",
      maximumBytes: 4_096
    )
    guard executablePath.hasPrefix("/") else {
      throw ToolCallArgumentsError.invalidArguments
    }
    let request = ProcessExecutionRequest(
      executable: URL(fileURLWithPath: executablePath),
      arguments: try arguments.requiredStringArray(
        named: "arguments",
        maximumCount: configuration.maximumArguments,
        maximumBytes: configuration.maximumArgumentBytes
      ),
      workingDirectory: workingDirectory,
      timeoutSeconds: try arguments.optionalInteger(
        named: "timeout_seconds",
        range: 1...configuration.maximumTimeoutSeconds
      ) ?? min(120, configuration.maximumTimeoutSeconds)
    )
    return try ProcessExecutionRequestValidator.validate(
      request,
      configuration: configuration
    )
  }
}
