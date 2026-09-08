import HexCore

public struct MacAccessibilitySnapshotTool: HostTool, Sendable {
  public let definition = ToolDefinition(
    name: "mac_accessibility_snapshot",
    description:
      "Read a bounded semantic Accessibility tree for one running macOS application. Secure text "
      + "values are never returned. Returns a single-use observation_id for one action in this run, "
      + "valid for at most 60 seconds. Observe again after every action to verify visible results. "
      + "macOS Accessibility permission is required.",
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
  private let observationLedger: MacAccessibilityObservationLedger
  private let sessionState: @Sendable () -> MacInteractionSessionState
  private let authorizationLedger = ToolAuthorizationLedger()

  public init(
    controller: any MacAccessibilityControlling,
    observationLedger: MacAccessibilityObservationLedger,
    sessionState: @escaping @Sendable () -> MacInteractionSessionState = {
      SystemMacInteractionSessionChecker().status()
    }
  ) {
    self.controller = controller
    self.observationLedger = observationLedger
    self.sessionState = sessionState
  }

  public func authorizationRequest(
    for call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> AuthorizationRequest {
    let request: (bundleIdentifier: String, maximumDepth: Int, maximumElements: Int)
    do {
      request = try validatedRequest(call)
    } catch {
      // Pure decoding only: no authorization, ledger mutation, or controller work has occurred.
      throw ToolCallValidationError(
        recovery:
          "Use only bundle_id, max_depth (integer 0 through 12), and max_elements "
          + "(integer 1 through 512) for mac_accessibility_snapshot. Supply the exact running "
          + "application bundle identifier. Correct the arguments and request a fresh observation.")
    }
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
      try Task.checkCancellation()
      try sessionState().requireAvailable()
      guard await controller.isTrusted(promptIfNeeded: false) else {
        throw MacToolError.accessibilityPermissionRequired
      }
      try Task.checkCancellation()
      try sessionState().requireAvailable()
      let snapshot = try await controller.snapshot(
        bundleIdentifier: request.bundleIdentifier,
        maximumDepth: request.maximumDepth,
        maximumElements: request.maximumElements
      )
      try Task.checkCancellation()
      guard snapshot.bundleIdentifier == request.bundleIdentifier else {
        throw MacToolError.accessibilityObservationFailed
      }
      try await observationLedger.record(snapshot, runID: context.runID)
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
