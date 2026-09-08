import HexCapabilities
import HexCore
import HexGatewayKit
import HexIPC
import Synchronization
import Testing

@Suite("Screen permission dispatch guard")
struct HexGatewayScreenPermissionToolExecutorTests {
  @Test
  func revocationBetweenActionsStopsBeforeCallingTheScreenHelper() async throws {
    let base = Executor()
    let permissions = Permissions()
    let guarded = HexGatewayScreenPermissionToolExecutor(
      base: base, sessionState: { .available }, status: { await permissions.status() })
    let context = ToolExecutionContext(runID: AgentRunID())
    let first = ToolCall(name: "screen_probe", arguments: [:])
    _ = try await guarded.authorizationRequest(for: first, in: context)
    #expect(try await guarded.execute(first, in: context).status == .success)
    await permissions.revoke()
    let second = ToolCall(name: "screen_probe", arguments: [:])
    _ = try await guarded.authorizationRequest(for: second, in: context)
    let denied = try await guarded.execute(second, in: context)
    #expect(denied.status == .failure)
    #expect(denied.requiresUserAttention)
    #expect(
      denied.output
        == .object(["error": .string("screen_permissions_required"), "dispatched": .boolean(false)])
    )
    #expect(await base.calls == 1)
  }

  @Test
  func unreachablePermissionCheckDoesNotDispatchOrPretendAccessIsDenied() async throws {
    let base = Executor()
    let guarded = HexGatewayScreenPermissionToolExecutor(
      base: base, sessionState: { .available },
      status: { throw GatewayFailure(code: .transportUnavailable, message: "Offline") })
    let result = try await guarded.execute(
      ToolCall(name: "screen_probe", arguments: [:]),
      in: ToolExecutionContext(runID: AgentRunID()))
    #expect(result.requiresUserAttention)
    #expect(
      result.output
        == .object([
          "error": .string("screen_permissions_unverified"), "dispatched": .boolean(false),
        ]))
    #expect(await base.calls == 0)
  }

  @Test
  func lockedOrUnavailableSessionNeverReachesPermissionOrActionDispatch() async throws {
    for state in [MacInteractionSessionState.locked, .unavailable] {
      let base = Executor()
      let guarded = HexGatewayScreenPermissionToolExecutor(
        base: base, sessionState: { state },
        status: {
          Issue.record("A blocked session must not invoke the external permission helper.")
          return GatewayScreenControlPermissionStatus(
            accessibilityGranted: true, screenRecordingGranted: true)
        })
      let result = try await guarded.execute(
        ToolCall(name: "screen_probe", arguments: [:]),
        in: ToolExecutionContext(runID: AgentRunID()))
      #expect(result.status == .failure)
      #expect(result.requiresUserAttention)
      #expect(await base.calls == 0)
    }
  }

  @Test
  func lockDuringPermissionCheckStopsBeforeActionDispatch() async throws {
    let base = Executor()
    let locked = Mutex(false)
    let guarded = HexGatewayScreenPermissionToolExecutor(
      base: base, sessionState: { locked.withLock { $0 ? .locked : .available } },
      status: {
        locked.withLock { $0 = true }
        return GatewayScreenControlPermissionStatus(
          accessibilityGranted: true, screenRecordingGranted: true)
      })
    let result = try await guarded.execute(
      ToolCall(name: "screen_probe", arguments: [:]),
      in: ToolExecutionContext(runID: AgentRunID()))
    #expect(result.requiresUserAttention)
    #expect(
      result.output
        == .object([
          "error": .string("mac_session_locked"), "dispatched": .boolean(false),
        ]))
    #expect(await base.calls == 0)
  }

  private actor Permissions {
    private var granted = true
    func revoke() { granted = false }
    func status() -> GatewayScreenControlPermissionStatus {
      GatewayScreenControlPermissionStatus(
        accessibilityGranted: true, screenRecordingGranted: granted)
    }
  }

  private actor Executor: ToolExecutor {
    private(set) var calls = 0
    func availableTools() -> [ToolDefinition] { [] }
    func authorizationRequest(for call: ToolCall, in context: ToolExecutionContext)
      -> AuthorizationRequest
    {
      AuthorizationRequest(
        runID: context.runID, toolCallID: call.id,
        capability: CapabilityID(rawValue: "mac.screen"), operation: "read",
        explanation: "Read screen")
    }
    func execute(_ call: ToolCall, in context: ToolExecutionContext) -> ToolResult {
      calls += 1
      return ToolResult(toolCallID: call.id, status: .success, output: .null)
    }
  }
}
