import ApplicationServices
import HexCore
import Testing

@testable import HexCapabilities

@Suite("Incomplete native observations")
struct MacAccessibilityIncompleteObservationTests {
  @Test
  func failedChildReadReportsDiagnosticsWithoutMintingAuthority() async throws {
    let error = MacAccessibilityReadError(
      elementPath: "0", axErrorCode: AXError.cannotComplete.rawValue, reason: .requestFailed)
    let result = try await snapshotResult(error: error)
    #expect(result.status == .failure)
    #expect(!result.requiresUserAttention)
    #expect(field(result, "error") == .string("accessibility_observation_incomplete"))
    #expect(field(result, "attribute") == .string("AXChildren"))
    #expect(field(result, "element_path") == .string("0"))
    #expect(field(result, "ax_error_code") == .integer(-25204))
    #expect(field(result, "reason") == .string("request_failed"))
    #expect(field(result, "dispatched") == .boolean(false))
    #expect(field(result, "observation_id") == nil)
    #expect(field(result, "elements") == nil)
  }

  @Test
  func lateAPIDisablementRemainsAPermissionBlocker() async throws {
    let result = try await snapshotResult(
      error: MacAccessibilityReadError(
        elementPath: "0.1", axErrorCode: AXError.apiDisabled.rawValue, reason: .requestFailed))
    #expect(result.status == .failure)
    #expect(result.requiresUserAttention)
    #expect(field(result, "error") == .string("accessibility_permission_required"))
    #expect(field(result, "dispatched") == .boolean(false))
    #expect(field(result, "observation_id") == nil)
  }

  private func snapshotResult(error: MacAccessibilityReadError) async throws -> ToolResult {
    let tool = MacAccessibilitySnapshotTool(
      controller: Controller(error: error), observationLedger: MacAccessibilityObservationLedger(),
      sessionState: { .available })
    let context = ToolExecutionContext(runID: AgentRunID())
    let call = ToolCall(
      name: "mac_accessibility_snapshot", arguments: ["bundle_id": .string("com.hex.fixture")])
    _ = try await tool.authorizationRequest(for: call, in: context)
    return try await tool.execute(call, in: context)
  }

  private func field(_ result: ToolResult, _ key: String) -> JSONValue? {
    guard case .object(let fields) = result.output else { return nil }
    return fields[key]
  }

  private struct Controller: MacAccessibilityControlling {
    let error: MacAccessibilityReadError
    func isTrusted(promptIfNeeded: Bool) async -> Bool { true }
    func snapshot(bundleIdentifier: String, maximumDepth: Int, maximumElements: Int)
      async throws -> MacAccessibilitySnapshot
    { throw error }
    func perform(_ request: MacAccessibilityActionRequest) async throws
      -> MacAccessibilityActionResult
    {
      Issue.record("An incomplete observation must never dispatch an action.")
      throw error
    }
  }
}
