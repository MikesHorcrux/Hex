import HexCore

/// Adds one reserved read-only tool while preserving the host's existing executor and policy.
public struct HexSelfInspectionToolExecutor: ToolExecutor, Sendable {
  public enum ToolError: Error, Equatable, Sendable {
    case reservedToolName
    case invalidArguments
  }

  public static let toolName = "hex_inspect_self"
  private let service: HexSelfKnowledgeService
  private let base: any ToolExecutor

  public init(service: HexSelfKnowledgeService, base: any ToolExecutor) {
    self.service = service
    self.base = base
  }

  public func availableTools() async throws -> [ToolDefinition] {
    try Task.checkCancellation()
    var tools = try await base.availableTools()
    guard !tools.contains(where: { $0.name == Self.toolName }) else {
      throw ToolError.reservedToolName
    }
    tools.append(
      ToolDefinition(
        name: Self.toolName,
        description:
          "Read Hex's own runtime paths, selected provider/model, source-location evidence, and built-in operating manual. No file contents, secrets, writes, downloads, or service changes.",
        inputSchema: [
          "type": .string("object"),
          "properties": .object([:]),
          "required": .array([]),
          "additionalProperties": .boolean(false),
        ]
      ))
    return tools.sorted { $0.name < $1.name }
  }

  public func authorizationRequest(
    for call: ToolCall, in context: ToolExecutionContext
  ) async throws -> AuthorizationRequest {
    try Task.checkCancellation()
    guard call.name == Self.toolName else {
      return try await base.authorizationRequest(for: call, in: context)
    }
    guard call.arguments.isEmpty else { throw ToolError.invalidArguments }
    return AuthorizationRequest(
      runID: context.runID,
      toolCallID: call.id,
      capability: CapabilityID(rawValue: "hex.self.read"),
      operation: "inspect",
      explanation: "Read Hex's non-secret runtime identity, locations, and built-in manual."
    )
  }

  public func execute(_ call: ToolCall, in context: ToolExecutionContext) async throws -> ToolResult
  {
    try Task.checkCancellation()
    guard call.name == Self.toolName else { return try await base.execute(call, in: context) }
    guard call.arguments.isEmpty else { return failure(call.id, code: "invalid_arguments") }
    do {
      let snapshot = try await service.snapshot(for: context.runID)
      return ToolResult(
        toolCallID: call.id,
        status: .success,
        output: .object([
          "runtime": snapshot,
          "manual": .string(HexSelfOperatingManual().text),
        ])
      )
    } catch HexSelfKnowledgeService.ServiceError.runUnavailable {
      return failure(call.id, code: "run_unavailable")
    }
  }

  private func failure(_ callID: ToolCallID, code: String) -> ToolResult {
    ToolResult(toolCallID: callID, status: .failure, output: .object(["error": .string(code)]))
  }
}
