import HexCore

public struct MacListApplicationsTool: HostTool, Sendable {
  public let definition = ToolDefinition(
    name: "mac_list_applications",
    description:
      "List running macOS applications and their bundle identifiers. Use a returned bundle_id "
      + "for activation or Accessibility tools.",
    inputSchema: HostToolSchema.object(properties: [:], required: [])
  )

  private let controller: any MacApplicationControlling
  private let authorizationLedger = ToolAuthorizationLedger()

  public init(controller: any MacApplicationControlling) {
    self.controller = controller
  }

  public func authorizationRequest(
    for call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> AuthorizationRequest {
    guard call.name == definition.name else {
      throw MacToolError.invalidArguments
    }
    _ = try ToolCallArguments(call.arguments, allowedNames: [])
    try await authorizationLedger.record(call: call, runID: context.runID)
    return AuthorizationRequest(
      runID: context.runID,
      toolCallID: call.id,
      capability: CapabilityID(rawValue: "mac.application.read"),
      operation: "list-running-applications",
      resource: "mac:running-applications",
      explanation: "Allow Hex to see which applications are currently running."
    )
  }

  public func execute(
    _ call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> ToolResult {
    do {
      try await authorizationLedger.take(call: call, runID: context.runID)
      let applications = try await controller.runningApplications()
      return MacToolResult.applications(applications, callID: call.id)
    } catch {
      await authorizationLedger.remove(callID: call.id, runID: context.runID)
      return try MacToolResult.failure(error, callID: call.id)
    }
  }
}
