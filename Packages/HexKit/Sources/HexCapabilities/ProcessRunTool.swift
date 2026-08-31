import CryptoKit
import Foundation
import HexCore

public struct ProcessRunTool: HostTool, Sendable {
  public let definition: ToolDefinition

  private let executor: any ProcessExecuting
  private let configuration: ProcessExecutionConfiguration
  private let environment: [String: String]
  /// Keeps exact-invocation grants stable only for this tool lifetime without persisting a
  /// guessable digest of possibly sensitive arguments.
  private let authorizationKey: SymmetricKey

  public init(
    executor: any ProcessExecuting,
    configuration: ProcessExecutionConfiguration = .standard,
    /// Host-selected environment; the model cannot supply arbitrary environment variables.
    environment: [String: String]? = nil
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
    self.environment = environment ?? ProcessExecutionEnvironment.standard()
    authorizationKey = SymmetricKey(size: .bits256)
  }

  public func authorizationRequest(
    for call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> AuthorizationRequest {
    try Task.checkCancellation()
    let request = try validatedRequest(for: call, in: context)
    try Task.checkCancellation()
    let argumentBytes = request.arguments.reduce(into: 0) { total, argument in
      total += argument.utf8.count
    }
    let environmentBytes = request.environment.reduce(into: 0) { total, entry in
      total += entry.key.utf8.count + entry.value.utf8.count
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
        "environment_variable_count": .integer(Int64(request.environment.count)),
        "environment_bytes": .integer(Int64(environmentBytes)),
        "timeout_seconds": .integer(Int64(request.timeoutSeconds)),
      ],
      explanation: "Allow Hex to run this exact local process invocation."
    )
  }

  public func execute(
    _ call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> ToolResult {
    try Task.checkCancellation()
    do {
      let request = try validatedRequest(for: call, in: context)
      let result = try await executor.execute(request)
      return ProcessToolResult.result(bounded(result), callID: call.id)
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
      environment: environment,
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

  private func bounded(_ result: ProcessExecutionResult) -> ProcessExecutionResult {
    guard result.output.count > configuration.maximumOutputBytes else {
      return result
    }
    return ProcessExecutionResult(
      termination: .outputLimitExceeded,
      output: Data(result.output.prefix(configuration.maximumOutputBytes)),
      durationMilliseconds: result.durationMilliseconds
    )
  }
}
