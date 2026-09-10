import Foundation
import HexCore
import Testing

@testable import HexGatewayKit

@Suite("Durable task mutation guard")
struct HexTaskGuardedToolExecutorTests {
  @Test(
    arguments: [
      "mac.accessibility.read", "mac.screen.observe", "browser.session.observe",
      "process.session.read", "mcp.tool.execute", "mac.accessibility.control",
    ], [false, true])
  func failedQualifiedReadsAreKnownWithoutSuppressingAttention(
    capability: String, attention: Bool
  ) async throws {
    let output: JSONValue = .object(["dispatched": .boolean(false)])
    let base = CountingTool(
      capability: capability, requiresUserAttention: attention, fails: true, output: output)
    let executor = HexTaskGuardedToolExecutor(base: base, effects: nil)
    let call = ToolCall(name: "fixture", arguments: [:])
    let context = ToolExecutionContext(runID: AgentRunID())
    _ = try await executor.authorizationRequest(for: call, in: context)
    let result = try await executor.execute(call, in: context)
    let qualified = capability != "mcp.tool.execute" && capability != "mac.accessibility.control"
    #expect(result.executionOutcome == (qualified ? .completed : nil))
    #expect(result.requiresUserAttention == attention)
    #expect(result.status == .failure)
    #expect(result.output == output)
    #expect(await base.executions == 1)
  }

  @Test(arguments: [
    "window-list", "snapshot", "window-focus", "foreground", "output-path", "other-server",
  ])
  func hostQualifiedNativeObservationsCanRepeatWithoutOpeningAnInputException(kind: String)
    async throws
  {
    let snapshot = kind == "snapshot" || kind == "output-path"
    let name =
      (kind == "other-server" ? "mcp_5_other_" : "mcp_8_peekaboo_")
      + (snapshot ? "see" : "window")
    var arguments: [String: JSONValue] =
      snapshot
      ? ["app_target": .string("PID:123"), "window_id": .integer(10)]
      : ["action": .string(kind == "window-focus" ? "focus" : "list"), "app": .string("Safari")]
    if kind == "foreground" { arguments["foreground"] = .boolean(true) }
    if kind == "output-path" { arguments["path"] = .string("/tmp/user-selected.png") }
    let original = ToolCall(name: name, arguments: arguments)
    let base = CountingTool(capability: name)
    let session = UUID()
    let native = HexGatewayPeekabooToolExecutor(base: base, sessionIdentity: { session })
    let executor = HexTaskGuardedToolExecutor(
      base: native,
      effects: PriorEffect(
        effect: AgentTaskEffect(
          runID: AgentRunID(), callID: original.id,
          result: ToolResult(
            toolCallID: original.id, status: .success, output: .string("old observation"))),
        fingerprint: try AgentTaskOperationFingerprint.data(for: original)))
    let next = ToolCall(name: name, arguments: arguments)
    let context = ToolExecutionContext(runID: AgentRunID())
    let authorization = try await executor.authorizationRequest(for: next, in: context)
    _ = try await executor.execute(next, in: context)
    let repeatable = kind == "window-list" || kind == "snapshot"
    #expect(authorization.capability.rawValue == (repeatable ? "mac.screen.observe" : name))
    #expect(await base.executions == (repeatable ? 1 : 0))
  }

  @Test(arguments: ["list", "select"])
  func hostQualifiedTabObservationCanRepeatButSelectionCannot(action: String) async throws {
    let name = "mcp_10_playwright_browser_tabs"
    let base = CountingTool(capability: name)
    let session = UUID()
    let browser = HexGatewayBrowserToolExecutor(base: base, sessionIdentity: { session })
    let original = ToolCall(name: name, arguments: ["action": .string(action)])
    let next = ToolCall(name: original.name, arguments: original.arguments)
    let effect = AgentTaskEffect(
      runID: AgentRunID(), callID: original.id,
      result: ToolResult(toolCallID: original.id, status: .success, output: .string("done")))
    let executor = HexTaskGuardedToolExecutor(
      base: browser,
      effects: PriorEffect(
        effect: effect, fingerprint: try AgentTaskOperationFingerprint.data(for: original)))
    let context = ToolExecutionContext(runID: AgentRunID())
    let request = try await executor.authorizationRequest(for: next, in: context)
    let result = try await executor.execute(next, in: context)
    #expect(request.toolCallID == next.id)
    #expect(request.runID == context.runID)
    #expect(request.capability.rawValue == (action == "list" ? "browser.session.observe" : name))
    #expect(await base.executions == (action == "list" ? 1 : 0))
    #expect(!result.requiresUserAttention)
    #expect(result.executionOutcome == (action == "list" ? nil : .completed))
  }

  @Test
  func executionDoesNotRefreshTheAuthorizationSnapshot() async throws {
    let base = CountingTool()
    let executor = HexTaskGuardedToolExecutor(base: base, effects: nil)
    let call = ToolCall(name: "mutate", arguments: [:])
    let context = ToolExecutionContext(runID: AgentRunID())
    _ = try await executor.authorizationRequest(for: call, in: context)
    _ = try await executor.execute(call, in: context)
    #expect(await base.authorizations == 1)
    #expect(await base.executions == 1)
    await executor.finishRun(context.runID)
    await #expect(throws: AgentTaskStorageError.self) {
      _ = try await executor.execute(call, in: context)
    }
    #expect(await base.executions == 1)
  }

  @Test
  func newProviderCallIdentityCannotRepeatAnEarlierMutation() async throws {
    let base = CountingTool()
    let original = ToolCall(name: "mutate", arguments: ["value": .string("once")])
    let next = ToolCall(name: original.name, arguments: original.arguments)
    let effect = AgentTaskEffect(
      runID: AgentRunID(), callID: original.id,
      result: ToolResult(toolCallID: original.id, status: .success, output: .string("done")))
    let executor = HexTaskGuardedToolExecutor(
      base: base,
      effects: PriorEffect(
        effect: effect, fingerprint: try AgentTaskOperationFingerprint.data(for: original)))
    let context = ToolExecutionContext(runID: AgentRunID())
    _ = try await executor.authorizationRequest(for: next, in: context)
    let result = try await executor.execute(next, in: context)
    #expect(!result.requiresUserAttention)
    #expect(result.executionOutcome == .completed)
    #expect(result.notExecutedReason == nil)
    #expect(result.status == .failure)
    #expect(await base.executions == 0)
  }

  @Test(arguments: ["missing", "failed", "attention"])
  func uncertainPriorOutcomesStillRequireReconciliation(outcome: String) async throws {
    let base = CountingTool(capability: "mac.accessibility.control")
    let original = ToolCall(name: "mac_accessibility_action", arguments: [:])
    let result: ToolResult? =
      outcome == "missing"
      ? nil
      : ToolResult(
        toolCallID: original.id, status: outcome == "failed" ? .failure : .success,
        output: .string("uncertain"), requiresUserAttention: outcome == "attention")
    let executor = HexTaskGuardedToolExecutor(
      base: base,
      effects: PriorEffect(
        effect: AgentTaskEffect(runID: AgentRunID(), callID: original.id, result: result),
        fingerprint: try AgentTaskOperationFingerprint.data(for: original)))
    let next = ToolCall(name: original.name, arguments: original.arguments)
    let context = ToolExecutionContext(runID: AgentRunID())
    _ = try await executor.authorizationRequest(for: next, in: context)
    let rejected = try await executor.execute(next, in: context)
    #expect(rejected.requiresUserAttention)
    #expect(rejected.notExecutedReason == nil)
    #expect(await base.executions == 0)
  }

  @Test(
    arguments: ["mac_activate_application", "mac_open_local_url"],
    ["native", "wrong-operation", "mcp"])
  func nativePresentationCanBeRequestedAgainWithFreshAuthorization(name: String, source: String)
    async throws
  {
    let operation =
      name == "mac_activate_application" ? "activate-application" : "open-local-preview"
    let base = CountingTool(
      capability: source == "mcp" ? "mcp.tool.execute" : "mac.application.control",
      operation: source == "wrong-operation" ? "write" : operation)
    let original = ToolCall(name: name, arguments: ["bundle_id": .string("com.apple.Safari")])
    let effect = AgentTaskEffect(
      runID: AgentRunID(), callID: original.id,
      result: ToolResult(
        toolCallID: original.id, status: .success, output: .string("opened earlier")))
    let executor = HexTaskGuardedToolExecutor(
      base: base,
      effects: PriorEffect(
        effect: effect, fingerprint: try AgentTaskOperationFingerprint.data(for: original)))
    let next = ToolCall(name: name, arguments: original.arguments)
    let context = ToolExecutionContext(runID: AgentRunID())
    _ = try await executor.authorizationRequest(for: next, in: context)
    let result = try await executor.execute(next, in: context)
    #expect(await base.authorizations == 1)
    #expect(await base.executions == (source == "native" ? 1 : 0))
    #expect(result.status == (source == "native" ? .success : .failure))
    await #expect(throws: AgentTaskStorageError.self) {
      _ = try await executor.execute(next, in: context)
    }
    #expect(await base.executions == (source == "native" ? 1 : 0))
  }

  @Test
  func nativePresentationPreservesNewUncertainty() async throws {
    let base = CountingTool(
      capability: "mac.application.control", operation: "open-local-preview",
      requiresUserAttention: true)
    let original = ToolCall(name: "mac_open_local_url", arguments: [:])
    let effect = AgentTaskEffect(
      runID: AgentRunID(), callID: original.id,
      result: ToolResult(
        toolCallID: original.id, status: .success, output: .string("opened earlier")))
    let executor = HexTaskGuardedToolExecutor(
      base: base,
      effects: PriorEffect(
        effect: effect, fingerprint: try AgentTaskOperationFingerprint.data(for: original)))
    let next = ToolCall(name: original.name, arguments: original.arguments)
    let context = ToolExecutionContext(runID: AgentRunID())
    _ = try await executor.authorizationRequest(for: next, in: context)
    let result = try await executor.execute(next, in: context)
    #expect(await base.executions == 1)
    #expect(result.requiresUserAttention)
    #expect(result.status == .failure)
    #expect(result.executionOutcome == nil)
    #expect(result.toolCallID == next.id)
  }

  @Test(arguments: ["workspace.write", "mcp.tool.execute"])
  func nativeRevisionCheckedPatchOwnsItsRepeatValidation(capability: String) async throws {
    let base = CountingTool(capability: capability)
    let original = ToolCall(name: "workspace_apply_patch", arguments: [:])
    let next = ToolCall(name: original.name, arguments: original.arguments)
    let effect = AgentTaskEffect(
      runID: AgentRunID(), callID: original.id,
      result: ToolResult(
        toolCallID: original.id, status: .failure,
        output: .object(["error": .string("revision_conflict")])))
    let executor = HexTaskGuardedToolExecutor(
      base: base,
      effects: PriorEffect(
        effect: effect, fingerprint: try AgentTaskOperationFingerprint.data(for: original)))
    let context = ToolExecutionContext(runID: AgentRunID())
    _ = try await executor.authorizationRequest(for: next, in: context)
    let result = try await executor.execute(next, in: context)
    let native = capability == "workspace.write"
    #expect(result.status == (native ? .success : .failure))
    #expect(await base.authorizations == 1)
    #expect(await base.executions == (native ? 1 : 0))
  }

  private struct PriorEffect: AgentTaskEffectReading {
    let effect: AgentTaskEffect
    let fingerprint: Data
    func previousTaskEffect(runID: AgentRunID, fingerprint: Data) -> AgentTaskEffect? {
      self.fingerprint == fingerprint ? effect : nil
    }
  }

  private actor CountingTool: ToolExecutor {
    let capability: String
    let operation: String
    let requiresUserAttention: Bool
    let fails: Bool
    let output: JSONValue
    var authorizations = 0
    var executions = 0
    init(
      capability: String = "workspace.write", operation: String = "write",
      requiresUserAttention: Bool = false, fails: Bool = false, output: JSONValue = .string("done")
    ) {
      self.capability = capability
      self.operation = operation
      self.requiresUserAttention = requiresUserAttention
      self.fails = fails
      self.output = output
    }
    func availableTools() -> [ToolDefinition] { [] }
    func authorizationRequest(for call: ToolCall, in context: ToolExecutionContext)
      -> AuthorizationRequest
    {
      authorizations += 1
      return AuthorizationRequest(
        runID: context.runID, toolCallID: call.id,
        capability: CapabilityID(rawValue: capability), operation: operation,
        explanation: "fixture")
    }
    func execute(_ call: ToolCall, in context: ToolExecutionContext) -> ToolResult {
      executions += 1
      return ToolResult(
        toolCallID: call.id, status: requiresUserAttention || fails ? .failure : .success,
        output: output, requiresUserAttention: requiresUserAttention)
    }
  }
}
