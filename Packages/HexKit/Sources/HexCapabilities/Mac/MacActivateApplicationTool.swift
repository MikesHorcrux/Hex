import HexCore

public struct MacActivateApplicationTool: HostTool, Sendable {
  public let definition = ToolDefinition(
    name: "mac_activate_application",
    description:
      "Activate a running macOS app or launch an installed app using an exact bundle identifier. "
      + "A later request can bring the same app forward again; a prior activation does not keep it focused.",
    inputSchema: HostToolSchema.object(
      properties: [
        "bundle_id": HostToolSchema.string(
          "The exact application bundle identifier returned by mac_list_applications.",
          maximumLength: 255
        )
      ],
      required: ["bundle_id"]
    )
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
    let bundleIdentifier = try validatedBundleIdentifier(call)
    try await authorizationLedger.record(call: call, runID: context.runID)
    return AuthorizationRequest(
      runID: context.runID,
      toolCallID: call.id,
      capability: CapabilityID(rawValue: "mac.application.control"),
      operation: "activate-application",
      resource: "bundle:\(bundleIdentifier)",
      details: ["bundle_id": .string(bundleIdentifier)],
      explanation: "Allow Hex to launch or bring this exact application to the foreground."
    )
  }

  public func execute(
    _ call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> ToolResult {
    do {
      let bundleIdentifier = try validatedBundleIdentifier(call)
      try await authorizationLedger.take(call: call, runID: context.runID)
      let result = try await controller.activateApplication(bundleIdentifier: bundleIdentifier)
      return MacToolResult.activation(result, callID: call.id)
    } catch {
      await authorizationLedger.remove(callID: call.id, runID: context.runID)
      return try MacToolResult.failure(error, callID: call.id)
    }
  }

  private func validatedBundleIdentifier(_ call: ToolCall) throws -> String {
    guard call.name == definition.name else {
      throw MacToolError.invalidArguments
    }
    let arguments = try ToolCallArguments(call.arguments, allowedNames: ["bundle_id"])
    return try MacTargetValidator.validateBundleIdentifier(
      arguments.requiredString(named: "bundle_id", maximumBytes: 255)
    )
  }
}
