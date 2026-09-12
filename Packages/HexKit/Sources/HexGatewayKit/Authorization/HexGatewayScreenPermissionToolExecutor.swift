import HexCapabilities
import HexCore
import HexIPC

/// Rechecks the responsible screen helper immediately before dispatch, including in Full Access.
/// The health catalog remains independent of TCC, so a revoked grant does not hide the tool.
public struct HexGatewayScreenPermissionToolExecutor: ToolExecutor {
  private let base: any ToolExecutor
  private let status: @Sendable () async throws -> GatewayScreenControlPermissionStatus
  private let sessionState: @Sendable () -> MacInteractionSessionState

  public init(
    base: any ToolExecutor,
    sessionState: @escaping @Sendable () -> MacInteractionSessionState = {
      SystemMacInteractionSessionChecker().status()
    },
    status: @escaping @Sendable () async throws -> GatewayScreenControlPermissionStatus
  ) {
    self.base = base
    self.status = status
    self.sessionState = sessionState
  }

  public func availableTools() async throws -> [ToolDefinition] { try await base.availableTools() }

  public func authorizationRequest(for call: ToolCall, in context: ToolExecutionContext)
    async throws
    -> AuthorizationRequest
  {
    try await base.authorizationRequest(for: call, in: context)
  }

  public func execute(_ call: ToolCall, in context: ToolExecutionContext) async throws -> ToolResult
  {
    try Task.checkCancellation()
    switch sessionState() {
    case .locked: return blocked(call, code: "mac_session_locked")
    case .unavailable: return blocked(call, code: "mac_session_unavailable")
    case .available: break
    }
    let permissions: GatewayScreenControlPermissionStatus
    do {
      permissions = try await status()
      try Task.checkCancellation()
    } catch is CancellationError { throw CancellationError() } catch {
      return blocked(call, code: "screen_permissions_unverified")
    }
    guard permissions.isGranted else {
      return blocked(call, code: "screen_permissions_required")
    }
    switch sessionState() {
    case .locked: return blocked(call, code: "mac_session_locked")
    case .unavailable: return blocked(call, code: "mac_session_unavailable")
    case .available: break
    }
    return try await base.execute(call, in: context)
  }

  private func blocked(_ call: ToolCall, code: String) -> ToolResult {
    ToolResult(
      toolCallID: call.id, status: .failure,
      output: .object(["error": .string(code), "dispatched": .boolean(false)]),
      requiresUserAttention: true)
  }
}
