import HexCore

public struct MacAccessibilitySnapshotTool: HostTool, Sendable {
  public let definition = ToolDefinition(
    name: "mac_accessibility_snapshot",
    description:
      "Read a bounded semantic Accessibility tree for one running macOS application. Secure text "
      + "values are never returned. macOS Accessibility permission is required.",
    inputSchema: HostToolSchema.object(
      properties: [
        "bundle_id": HostToolSchema.string(
          "The exact bundle identifier of a running application.",
          maximumLength: 255
        ),
        "max_depth": HostToolSchema.integer(
          "Maximum Accessibility tree depth.",
          minimum: 0,
          maximum: 12
        ),
        "max_elements": HostToolSchema.integer(
          "Maximum number of returned elements.",
          minimum: 1,
          maximum: 512
        ),
      ],
      required: ["bundle_id"]
    )
  )

  private let controller: any MacAccessibilityControlling
  private let authorizationLedger = ToolAuthorizationLedger()

  public init(controller: any MacAccessibilityControlling) {
    self.controller = controller
  }

  public func authorizationRequest(
    for call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> AuthorizationRequest {
    let request = try validatedRequest(call)
    try await authorizationLedger.record(call: call, runID: context.runID)
    return AuthorizationRequest(
      runID: context.runID,
      toolCallID: call.id,
      capability: CapabilityID(rawValue: "mac.accessibility.read"),
      operation: "snapshot-accessibility-tree",
      resource: "bundle:\(request.bundleIdentifier)",
      details: [
        "bundle_id": .string(request.bundleIdentifier),
        "max_depth": .integer(Int64(request.maximumDepth)),
        "max_elements": .integer(Int64(request.maximumElements)),
      ],
      explanation: "Allow Hex to inspect the visible controls in this exact application."
    )
  }

  public func execute(
    _ call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> ToolResult {
    do {
      let request = try validatedRequest(call)
      try await authorizationLedger.take(call: call, runID: context.runID)
      guard await controller.isTrusted(promptIfNeeded: true) else {
        throw MacToolError.accessibilityPermissionRequired
      }
      let snapshot = try await controller.snapshot(
        bundleIdentifier: request.bundleIdentifier,
        maximumDepth: request.maximumDepth,
        maximumElements: request.maximumElements
      )
      return MacToolResult.snapshot(snapshot, callID: call.id)
    } catch {
      await authorizationLedger.remove(callID: call.id, runID: context.runID)
      return try MacToolResult.failure(error, callID: call.id)
    }
  }

  private func validatedRequest(
    _ call: ToolCall
  ) throws -> (bundleIdentifier: String, maximumDepth: Int, maximumElements: Int) {
    guard call.name == definition.name else {
      throw MacToolError.invalidArguments
    }
    let arguments = try ToolCallArguments(
      call.arguments,
      allowedNames: ["bundle_id", "max_depth", "max_elements"]
    )
    let bundleIdentifier = try MacTargetValidator.validateBundleIdentifier(
      arguments.requiredString(named: "bundle_id", maximumBytes: 255)
    )
    return (
      bundleIdentifier,
      try arguments.optionalInteger(named: "max_depth", range: 0...12) ?? 6,
      try arguments.optionalInteger(named: "max_elements", range: 1...512) ?? 200
    )
  }
}
