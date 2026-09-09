import Foundation
import HexCore

public struct ProcessStartTool: HostTool {
  public let definition: ToolDefinition
  private let manager: ProcessSessionManager
  private let base: ProcessRunTool
  private let identities: ProcessAuthorizationLedger
  private let calls = ToolAuthorizationLedger(maximumEntries: 64)

  public init(manager: ProcessSessionManager, environment: [String: String]? = nil) throws {
    self.manager = manager
    let ledger = ProcessAuthorizationLedger()
    identities = ledger
    base = ProcessRunTool(
      executor: POSIXProcessExecutor(),
      configuration: try ProcessExecutionConfiguration(maximumTimeoutSeconds: 28_800),
      environment: environment, authorizationLedger: ledger)
    definition = ToolDefinition(
      name: "process_start",
      description:
        "Start an authorized coding command or direct REPL in a persistent resident-owned session. "
        + "Returns a session ID immediately; use process_read to observe progress and exit. Pipe is the default. "
        + "Use retained lifetime only for servers/REPLs needed after this task. Never repeat an uncertain start.",
      inputSchema: HostToolSchema.object(
        properties: [
          "executable": HostToolSchema.string(
            "Absolute executable path; no implicit shell.", maximumLength: 4_096),
          "arguments": HostToolSchema.stringArray(
            "Exact argv; do not include secrets.", maximumItems: 256, maximumItemLength: 65_536),
          "transport": HostToolSchema.stringEnum(
            "Pipe for commands; pty for a direct interactive REPL.", values: ["pipe", "pty"]),
          "lifetime": HostToolSchema.stringEnum(
            "Task sessions stop when the task ends; retained sessions keep running until stopped or their deadline.",
            values: ["task", "retained"]),
          "timeout_seconds": HostToolSchema.integer(
            "Deadline, including sleep. Default 1800 seconds.", minimum: 1, maximum: 28_800),
        ], required: ["executable", "arguments"]))
  }

  private func projected(_ call: ToolCall) throws -> (ToolCall, String, Bool) {
    guard call.name == definition.name else { throw ProcessSessionError.invalidRequest }
    let args = try ToolCallArguments(
      call.arguments,
      allowedNames: ["executable", "arguments", "transport", "lifetime", "timeout_seconds"])
    let transport = try args.optionalString(named: "transport", maximumBytes: 8) ?? "pipe"
    let lifetime = try args.optionalString(named: "lifetime", maximumBytes: 8) ?? "task"
    guard ["pipe", "pty"].contains(transport), ["task", "retained"].contains(lifetime) else {
      throw ProcessSessionError.invalidRequest
    }
    var values = call.arguments
    values.removeValue(forKey: "transport")
    values.removeValue(forKey: "lifetime")
    values["timeout_seconds"] = .integer(
      Int64(try args.optionalInteger(named: "timeout_seconds", range: 1...28_800) ?? 1_800))
    return (
      ToolCall(id: call.id, name: "process_run", arguments: values), transport,
      lifetime == "retained"
    )
  }

  public func authorizationRequest(for call: ToolCall, in context: ToolExecutionContext)
    async throws -> AuthorizationRequest
  {
    let (projected, transport, retained) = try projected(call)
    _ = try await manager.scope(context)
    let request = try await base.authorizationRequest(for: projected, in: context)
    try await calls.record(call: call, runID: context.runID)
    var details = request.details
    details["transport"] = .string(transport)
    details["retained"] = .boolean(retained)
    return AuthorizationRequest(
      runID: context.runID, toolCallID: call.id,
      capability: CapabilityID(rawValue: "process.session.execute"), operation: "start_session",
      resource: (request.resource ?? "") + ":\(transport):\(retained)", details: details,
      explanation:
        "Allow this exact process and its session lifetime. Future input requires separate authorization."
    )
  }

  public func execute(_ call: ToolCall, in context: ToolExecutionContext) async throws -> ToolResult
  {
    try await calls.take(call: call, runID: context.runID)
    let (_, transport, retained) = try projected(call)
    guard let snapshot = await identities.take(runID: context.runID, toolCallID: call.id),
      try ProcessExecutionIdentity.capture(for: snapshot.request) == snapshot.identity
    else { throw ProcessSessionError.unauthorized }
    let scope = try await manager.scope(context)
    try Task.checkCancellation()
    let record = try await manager.start(
      request: ProcessSupervisorRequest(
        executable: snapshot.request.executable.path, arguments: snapshot.request.arguments,
        directory: snapshot.request.workingDirectory.path,
        environment: snapshot.request.environment,
        tty: transport == "pty", timeoutSeconds: snapshot.request.timeoutSeconds,
        identity: snapshot.identity),
      scope: scope, context: context, retained: retained, callID: call.id)
    return ToolResult(
      toolCallID: call.id, status: .success, output: try ProcessSessionTool.value(record),
      requiresUserAttention: record.terminal && !record.cleanupConfirmed)
  }
}
