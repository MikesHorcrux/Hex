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
        "observation_id": .string(snapshot.observationID),
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
        "observation_id": .string(result.observationID),
        "window_reference": result.windowReference.map(JSONValue.string) ?? .null,
        "dispatched": .boolean(true),
        "outcome_verified": .boolean(false),
        "next_step": .string("Observe the application again to verify the visible outcome."),
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
    case MacToolError.accessibilityObservationStale:
      code = "accessibility_observation_stale"
    case MacToolError.interactionSessionLocked:
      code = "mac_session_locked"
    case MacToolError.interactionSessionUnavailable:
      code = "mac_session_unavailable"
    case MacToolError.accessibilityElementNotFound:
      code = "accessibility_element_not_found"
    case MacToolError.accessibilityElementAmbiguous:
      code = "accessibility_element_ambiguous"
    case MacToolError.accessibilityActionUnsupported:
      code = "accessibility_action_unsupported"
    case MacToolError.accessibilityActionFailed, MacToolError.accessibilityActionOutcomeUnknown:
      code = "accessibility_action_outcome_unknown"
    default:
      throw error
    }
    let outcomeUnknown = code == "accessibility_action_outcome_unknown"
    let requiresAttention =
      outcomeUnknown
      || [
        "accessibility_permission_required",
        "mac_session_locked", "mac_session_unavailable",
      ].contains(code)
    var output: [String: JSONValue] = ["error": .string(code)]
    if code.hasPrefix("accessibility_") || code.hasPrefix("mac_session_") {
      output["dispatched"] = .boolean(outcomeUnknown)
      output["outcome_verified"] = .boolean(false)
    }
    if outcomeUnknown {
      output["outcome_unknown"] = .boolean(true)
      output["next_step"] = .string(
        "The action may have taken effect. Observe the application before considering any retry.")
    } else if code == "accessibility_observation_stale" {
      output["next_step"] = .string("Obtain a fresh observation before planning another action.")
    }
    return ToolResult(
      toolCallID: callID,
      status: .failure,
      output: .object(output),
      requiresUserAttention: requiresAttention
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
    if let windowReference = element.windowReference {
      value["window_reference"] = .string(windowReference)
    }
    return .object(value)
  }
}
