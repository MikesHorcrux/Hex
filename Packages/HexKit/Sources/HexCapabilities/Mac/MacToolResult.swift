import Foundation
import HexCore

enum MacToolResult {
  static func applications(
    _ applications: [MacApplicationSnapshot],
    callID: ToolCallID
  ) -> ToolResult {
    ToolResult(
      toolCallID: callID,
      status: .success,
      output: .object([
        "applications": .array(
          applications.map { application in
            .object([
              "bundle_id": .string(application.bundleIdentifier),
              "name": .string(application.localizedName),
              "process_id": .integer(Int64(application.processIdentifier)),
              "is_active": .boolean(application.isActive),
              "is_hidden": .boolean(application.isHidden),
            ])
          })
      ])
    )
  }

  static func activation(
    _ result: MacApplicationActivationResult,
    callID: ToolCallID
  ) -> ToolResult {
    ToolResult(
      toolCallID: callID,
      status: .success,
      output: .object([
        "bundle_id": .string(result.bundleIdentifier),
        "was_running": .boolean(result.wasRunning),
        "activation_requested": .boolean(true),
      ])
    )
  }

  static func openedURL(_ url: URL, callID: ToolCallID) -> ToolResult {
    ToolResult(
      toolCallID: callID,
      status: .success,
      output: .object([
        "url": .string(url.absoluteString),
        "opened": .boolean(true),
      ])
    )
  }

  static func snapshot(
    _ snapshot: MacAccessibilitySnapshot,
    callID: ToolCallID
  ) -> ToolResult {
    ToolResult(
      toolCallID: callID,
      status: .success,
      output: .object([
        "application": .object([
          "bundle_id": .string(snapshot.bundleIdentifier),
          "name": .string(snapshot.applicationName),
          "process_id": .integer(Int64(snapshot.processIdentifier)),
        ]),
        "elements": .array(snapshot.elements.map(elementValue)),
        "is_truncated": .boolean(snapshot.isTruncated),
      ])
    )
  }

  static func accessibilityAction(
    _ result: MacAccessibilityActionResult,
    callID: ToolCallID
  ) -> ToolResult {
    ToolResult(
      toolCallID: callID,
      status: .success,
      output: .object([
        "bundle_id": .string(result.bundleIdentifier),
        "path": .string(result.path),
        "action": .string(result.action.rawValue),
        "performed": .boolean(true),
      ])
    )
  }

  static func failure(_ error: any Error, callID: ToolCallID) throws -> ToolResult {
    if error is CancellationError {
      throw CancellationError()
    }
    let code: String
    switch error {
    case ToolCallArgumentsError.invalidArguments, MacToolError.invalidArguments:
      code = "invalid_arguments"
    case ToolAuthorizationLedgerError.authorizationRequired,
      MacToolError.authorizationRequired:
      code = "authorization_required"
    case ToolAuthorizationLedgerError.capacityExceeded,
      ToolAuthorizationLedgerError.conflictingRequest,
      MacToolError.authorizationStateUnavailable:
      code = "authorization_state_unavailable"
    case MacToolError.applicationNotFound:
      code = "application_not_found"
    case MacToolError.activationFailed:
      code = "activation_failed"
    case MacToolError.openURLFailed:
      code = "open_url_failed"
    case MacToolError.accessibilityPermissionRequired:
      code = "accessibility_permission_required"
    case MacToolError.accessibilityObservationFailed:
      code = "accessibility_observation_failed"
    case MacToolError.accessibilityElementNotFound:
      code = "accessibility_element_not_found"
    case MacToolError.accessibilityElementAmbiguous:
      code = "accessibility_element_ambiguous"
    case MacToolError.accessibilityActionUnsupported:
      code = "accessibility_action_unsupported"
    case MacToolError.accessibilityActionFailed:
      code = "accessibility_action_failed"
    default:
      throw error
    }
    return ToolResult(
      toolCallID: callID,
      status: .failure,
      output: .object(["error": .string(code)]),
      requiresUserAttention: code == "accessibility_permission_required"
    )
  }

  private static func elementValue(_ element: MacAccessibilityElementSnapshot) -> JSONValue {
    var value: [String: JSONValue] = [
      "path": .string(element.path),
      "role": .string(element.role),
      "child_count": .integer(Int64(element.childCount)),
      "actions": .array(element.actions.map(JSONValue.string)),
    ]
    if let subrole = element.subrole { value["subrole"] = .string(subrole) }
    if let title = element.title { value["title"] = .string(title) }
    if let label = element.label { value["label"] = .string(label) }
    if let valueText = element.value { value["value"] = .string(valueText) }
    if let identifier = element.identifier { value["identifier"] = .string(identifier) }
    if let isEnabled = element.isEnabled { value["is_enabled"] = .boolean(isEnabled) }
    if let isFocused = element.isFocused { value["is_focused"] = .boolean(isFocused) }
    return .object(value)
  }
}
