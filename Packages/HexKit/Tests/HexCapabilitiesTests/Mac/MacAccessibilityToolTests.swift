import Foundation
import HexCapabilities
import HexCore
import Testing

@Suite("Mac Accessibility tools")
struct MacAccessibilityToolTests {
  @Test
  func malformedObservationIsRecoverableBeforeAuthorizationAndCannotExecute() async throws {
    let controller = AccessibilityController()
    let tool = MacAccessibilityActionTool(
      controller: controller, observationLedger: MacAccessibilityObservationLedger(),
      sessionState: { .available })
    let call = ToolCall(
      name: "mac_accessibility_action",
      arguments: [
        "bundle_id": .string("com.apple.Safari"), "action": .string("press"),
        "identifier": .string("NewTabButton"), "observation_id": .string("?"),
      ])
    let context = ToolExecutionContext(runID: AgentRunID())
    await #expect(throws: ToolCallValidationError.self) {
      try await tool.authorizationRequest(for: call, in: context)
    }
    let result = try await tool.execute(call, in: context)
    #expect(result.status == .failure)
    #expect(await controller.lastAction == nil)
  }

  @Test
  func snapshotAndActionUseExactApplicationAndSelector() async throws {
    let controller = AccessibilityController()
    let observations = MacAccessibilityObservationLedger()
    let snapshotTool = MacAccessibilitySnapshotTool(
      controller: controller, observationLedger: observations, sessionState: { .available })
    let actionTool = MacAccessibilityActionTool(
      controller: controller, observationLedger: observations, sessionState: { .available })
    let context = ToolExecutionContext(runID: AgentRunID())
    let snapshotCall = ToolCall(
      id: ToolCallID(rawValue: "ax-snapshot"),
      name: "mac_accessibility_snapshot",
      arguments: [
        "bundle_id": .string("com.apple.Safari"),
        "max_depth": .integer(4),
        "max_elements": .integer(50),
      ]
    )

    let request = try await snapshotTool.authorizationRequest(for: snapshotCall, in: context)
    #expect(request.capability.rawValue == "mac.accessibility.read")
    #expect(request.resource == "bundle:com.apple.Safari")
    let snapshot = try await snapshotTool.execute(snapshotCall, in: context)
    #expect(snapshot.status == .success)
    guard case .object(let output) = snapshot.output,
      case .string(let observationID) = output["observation_id"]
    else {
      Issue.record("Snapshot requires a receipt")
      return
    }

    let actionCall = ToolCall(
      id: ToolCallID(rawValue: "ax-action"),
      name: "mac_accessibility_action",
      arguments: [
        "bundle_id": .string("com.apple.Safari"),
        "action": .string("press"),
        "observation_id": .string(observationID),
        "path": .string("0.1"),
      ]
    )
    let actionRequest = try await actionTool.authorizationRequest(for: actionCall, in: context)
    #expect(actionRequest.capability.rawValue == "mac.accessibility.control")
    #expect(actionRequest.details["path"] == .string("0.1"))
    let actionResult = try await actionTool.execute(actionCall, in: context)
    #expect(actionResult.status == .success)
    #expect(await controller.lastAction?.selector.path == "0.1")
  }

  @Test
  func reportsPermissionRequirementWithoutCallingTheControllerAction() async throws {
    let controller = AccessibilityController(isTrusted: false)
    let observations = MacAccessibilityObservationLedger()
    let tool = MacAccessibilityActionTool(
      controller: controller, observationLedger: observations, sessionState: { .available })
    let context = ToolExecutionContext(runID: AgentRunID())
    let receipt = MacAccessibilitySnapshot(
      bundleIdentifier: "com.apple.Safari", applicationName: "Safari", processIdentifier: 42,
      elements: [.init(path: "0.1", role: "AXTextField", identifier: "AddressField")],
      isTruncated: false)
    try await observations.record(receipt, runID: context.runID)
    let call = ToolCall(
      id: ToolCallID(rawValue: "ax-permission"),
      name: "mac_accessibility_action",
      arguments: [
        "bundle_id": .string("com.apple.Safari"),
        "action": .string("focus"),
        "observation_id": .string(receipt.observationID),
        "identifier": .string("AddressField"),
      ]
    )

    _ = try await tool.authorizationRequest(for: call, in: context)
    let result = try await tool.execute(call, in: context)

    #expect(result.status == .failure)
    #expect(result.requiresUserAttention)
    #expect(
      result.output
        == .object([
          "error": .string("accessibility_permission_required"),
          "dispatched": .boolean(false), "outcome_verified": .boolean(false),
        ])
    )
    #expect(await controller.lastAction == nil)
  }

  private actor AccessibilityController: MacAccessibilityControlling {
    private let trusted: Bool
    private(set) var lastAction: MacAccessibilityActionRequest?

    init(isTrusted: Bool = true) {
      trusted = isTrusted
    }

    func isTrusted(promptIfNeeded: Bool) async -> Bool {
      trusted
    }

    func snapshot(
      bundleIdentifier: String,
      maximumDepth: Int,
      maximumElements: Int
    ) async throws -> MacAccessibilitySnapshot {
      MacAccessibilitySnapshot(
        bundleIdentifier: bundleIdentifier,
        applicationName: "Safari",
        processIdentifier: 42,
        elements: [
          MacAccessibilityElementSnapshot(
            path: "0.1",
            role: "AXButton",
            title: "Reload",
            actions: ["AXPress"]
          )
        ],
        isTruncated: false
      )
    }

    func perform(
      _ request: MacAccessibilityActionRequest
    ) async throws -> MacAccessibilityActionResult {
      lastAction = request
      return MacAccessibilityActionResult(
        bundleIdentifier: request.bundleIdentifier,
        path: request.selector.path ?? "unknown",
        action: request.action, observationID: request.observationID
      )
    }
  }
}
