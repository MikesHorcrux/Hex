import CryptoKit
import Foundation
import HexCore

public struct ProcessRunTool: HostTool, Sendable {
  public let definition: ToolDefinition

  private let executor: any ProcessExecuting
  private let configuration: ProcessExecutionConfiguration
  private let environment: [String: String]
  private let maximumAuthorizationDetailsBytes: Int
  private let authorizationLedger: ProcessAuthorizationLedger
  /// Keeps exact-invocation grants stable only for this tool lifetime without persisting a
  /// guessable digest of possibly sensitive arguments.
  private let authorizationKey: SymmetricKey

  public init(
    executor: any ProcessExecuting,
    configuration: ProcessExecutionConfiguration = .standard,
    /// Host-selected environment; the model cannot supply arbitrary environment variables.
    environment: [String: String]? = nil,
    /// Must match the configuration used by the injected authorization center. Process details
    /// are rejected before a snapshot is recorded when they exceed this byte limit.
    authorizationConfiguration: CapabilityAuthorizationCenterConfiguration = .standard,
    authorizationLedger: ProcessAuthorizationLedger? = nil
  ) {
    definition = ToolDefinition(
      name: "process_run",
      description:
        "Run one non-interactive local executable with a bounded output preview and no implicit shell. "
        + "When output capture is configured, the full combined output is saved as a local artifact. "
        + "Authorization shows the complete escaped argv; never put secrets in arguments. "
        + "Injected environment values remain private and only names, count, and bytes are shown.",
      inputSchema: HostToolSchema.object(
        properties: [
          "executable": HostToolSchema.string(
            "An absolute executable path. No shell interpolation is performed.",
            maximumLength: 4_096
          ),
          "arguments": HostToolSchema.stringArray(
            "The exact argument vector passed to the executable; every argument is displayed in "
              + "authorization, so never put secrets here.",
            maximumItems: configuration.maximumArguments,
            maximumItemLength: configuration.maximumArgumentBytes
          ),
          "timeout_seconds": HostToolSchema.integer(
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
    // The standard center cap is an upper bound even when a caller supplies a larger custom
    // center cap; a smaller supplied cap is preserved and therefore remains fail-closed.
    self.maximumAuthorizationDetailsBytes = min(
      authorizationConfiguration.maximumDetailsBytes,
      CapabilityAuthorizationCenterConfiguration.standard.maximumDetailsBytes
    )
    self.authorizationLedger = authorizationLedger ?? ProcessAuthorizationLedger()
    authorizationKey = SymmetricKey(size: .bits256)
  }

  public func authorizationRequest(
    for call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> AuthorizationRequest {
    do {
      try Task.checkCancellation()
      let request = try validatedRequest(for: call, in: context)
      let identity = try ProcessExecutionIdentity.capture(for: request)
      let argumentBytes = request.arguments.reduce(0) { total, argument in
        total + argument.utf8.count
      }
      guard let environmentBytes = ProcessExecutionEnvironment.byteCount(request.environment) else {
        throw ProcessExecutionError.invalidRequest
      }

      guard
        let renderedArguments = ProcessPromptText.renderArguments(
          [request.executable.path] + request.arguments,
          maximumBytes: maximumAuthorizationDetailsBytes
        )
      else {
        throw ProcessExecutionError.authorizationDetailsTooLarge
      }
      let environmentNames = request.environment.keys.sorted()
      let environmentNamesBytes: Int
      do {
        environmentNamesBytes = try JSONEncoder().encode(environmentNames).count
      } catch {
        throw ProcessExecutionError.invalidRequest
      }
      guard environmentNamesBytes <= maximumAuthorizationDetailsBytes else {
        throw ProcessExecutionError.authorizationDetailsTooLarge
      }

      let details: [String: JSONValue] = [
        "executable": .string(request.executable.path),
        "working_directory": .string(request.workingDirectory.path),
        "argv": .array(renderedArguments.map { .string($0) }),
        "argv_count": .integer(Int64(request.arguments.count + 1)),
        "argument_count": .integer(Int64(request.arguments.count)),
        "argument_bytes": .integer(Int64(argumentBytes)),
        "environment_names": .array(
          environmentNames.map { .string($0) }
        ),
        "environment_variable_count": .integer(Int64(request.environment.count)),
        "environment_bytes": .integer(Int64(environmentBytes)),
        "executable_identity": identityValue(identity.executable),
        "working_directory_identity": identityValue(identity.workingDirectory),
        "timeout_seconds": .integer(Int64(request.timeoutSeconds)),
      ]
      let detailsBytes: Int
      do {
        detailsBytes = try JSONEncoder().encode(details).count
      } catch {
        throw ProcessExecutionError.invalidRequest
      }
      guard detailsBytes <= maximumAuthorizationDetailsBytes else {
        throw ProcessExecutionError.authorizationDetailsTooLarge
      }

      try Task.checkCancellation()
      // Keep a bounded pending snapshot so the external authorization decision can be followed by
      // an identity comparison; this is not itself an authorization grant. Recording is last so
      // all prompt-size validation completes before state can become pending.
      try await authorizationLedger.record(
        runID: context.runID,
        toolCallID: call.id,
        request: request,
        identity: identity
      )
      try Task.checkCancellation()
      return AuthorizationRequest(
        runID: context.runID,
        toolCallID: call.id,
        capability: CapabilityID(rawValue: "process.execute"),
        operation: "run",
        resource: ProcessAuthorizationResource.resource(
          for: request,
          identity: identity,
          key: authorizationKey
        ),
        details: details,
        explanation: "Allow Hex to run this exact local process invocation."
      )
    } catch {
      // A cancelled or malformed authorization attempt must not leave an approval snapshot that a
      // later retry could consume. The ledger operation itself is non-throwing and actor-owned.
      await authorizationLedger.remove(runID: context.runID, toolCallID: call.id)
      throw error
    }
  }

  public func execute(
    _ call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> ToolResult {
    do {
      try Task.checkCancellation()
      let request = try validatedRequest(for: call, in: context)
      guard
        let snapshot = await authorizationLedger.take(
          runID: context.runID,
          toolCallID: call.id
        )
      else {
        throw ProcessExecutionError.authorizationRequired
      }
      try Task.checkCancellation()
      guard request == snapshot.request else {
        throw ProcessExecutionError.invalidRequest
      }
      guard try ProcessExecutionIdentity.capture(for: request) == snapshot.identity else {
        throw ProcessExecutionError.invalidRequest
      }
      let result = try await executor.execute(
        request.requiringIdentity(
          snapshot.identity,
          outputArtifactMetadata: ArtifactMetadata(
            runID: context.runID, toolCallID: call.id, mediaType: "application/octet-stream")))
      // The executor returned a known outcome. Preserve it for the runtime journal even if the
      // task was cancelled while this actor resumed; cancellation must not hide completed effects.
      return ProcessToolResult.result(bounded(result), callID: call.id)
    } catch {
      // This also covers validation/cancellation before take(), where a pending authorization may
      // otherwise survive until the ledger TTL expires.
      await authorizationLedger.remove(runID: context.runID, toolCallID: call.id)
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
      termination: result.outputArtifact == nil ? .outputLimitExceeded : result.termination,
      output: Data(result.output.prefix(configuration.maximumOutputBytes)),
      durationMilliseconds: result.durationMilliseconds,
      outputArtifact: result.outputArtifact, totalOutputBytes: result.totalOutputBytes,
      outputIsComplete: result.outputArtifact == nil ? false : result.outputIsComplete,
      outputCaptureFailure: result.outputCaptureFailure
    )
  }

  private func identityValue(
    _ identity: ProcessExecutionIdentity.FileIdentity
  ) -> JSONValue {
    .object([
      "device": .integer(Int64(exactly: identity.device) ?? Int64.max),
      "inode": .integer(Int64(exactly: identity.inode) ?? Int64.max),
      "mode": .integer(Int64(exactly: identity.mode) ?? Int64.max),
      "size": .integer(identity.size),
      "modified_seconds": .integer(identity.modifiedSeconds),
      "modified_nanoseconds": .integer(identity.modifiedNanoseconds),
      "changed_seconds": .integer(identity.changedSeconds),
      "changed_nanoseconds": .integer(identity.changedNanoseconds),
    ])
  }
}
