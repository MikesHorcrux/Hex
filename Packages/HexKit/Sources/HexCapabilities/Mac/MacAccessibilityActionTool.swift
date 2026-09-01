import CryptoKit
import Foundation
import HexCore

public struct MacAccessibilityActionTool: HostTool, Sendable {
  public let definition = ToolDefinition(
    name: "mac_accessibility_action",
    description:
      "Press, focus, or set the value of one exact element in a running macOS application's "
      + "Accessibility tree. Use a path or exact attributes from mac_accessibility_snapshot. "
      + "Secure text fields are not writable because tool arguments may be journaled. macOS "
      + "Accessibility permission is required.",
    inputSchema: HostToolSchema.object(
      properties: [
        "bundle_id": HostToolSchema.string(
          "The exact bundle identifier of a running application.",
          maximumLength: 255
        ),
        "action": HostToolSchema.stringEnum(
          "The Accessibility action to perform.",
          values: MacAccessibilityAction.allCases.map(\.rawValue)
        ),
        "path": HostToolSchema.string(
          "An exact element path returned by mac_accessibility_snapshot.",
          maximumLength: 512
        ),
        "identifier": HostToolSchema.string(
          "An exact Accessibility identifier.",
          maximumLength: 1_024
        ),
        "role": HostToolSchema.string(
          "An exact Accessibility role such as AXButton.",
          maximumLength: 256
        ),
        "title": HostToolSchema.string(
          "An exact Accessibility title.",
          maximumLength: 1_024
        ),
        "occurrence": HostToolSchema.integer(
          "Zero-based match index when attributes select more than one element.",
          minimum: 0,
          maximum: 2_047
        ),
        "value": HostToolSchema.string(
          "Non-secret text for set_value. Never provide passwords, tokens, or other secrets; tool "
            + "calls may be journaled. The text is hashed, not copied, in the authorization resource.",
          maximumLength: 16_384
        ),
      ],
      required: ["bundle_id", "action"]
    )
  )

  private let controller: any MacAccessibilityControlling
  private let authorizationLedger = ToolAuthorizationLedger()
  private let authorizationKey = SymmetricKey(size: .bits256)

  public init(controller: any MacAccessibilityControlling) {
    self.controller = controller
  }

  public func authorizationRequest(
    for call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> AuthorizationRequest {
    let request = try validatedRequest(call)
    let resource = try authorizationResource(call)
    try await authorizationLedger.record(call: call, runID: context.runID)
    var details: [String: JSONValue] = [
      "bundle_id": .string(request.bundleIdentifier),
      "action": .string(request.action.rawValue),
    ]
    if let path = request.selector.path { details["path"] = .string(path) }
    if let identifier = request.selector.identifier {
      details["identifier"] = .string(identifier)
    }
    if let role = request.selector.role { details["role"] = .string(role) }
    if let title = request.selector.title { details["title"] = .string(title) }
    if let occurrence = request.selector.occurrence {
      details["occurrence"] = .integer(Int64(occurrence))
    }
    if let value = request.value {
      details["value_bytes"] = .integer(Int64(value.utf8.count))
    }
    return AuthorizationRequest(
      runID: context.runID,
      toolCallID: call.id,
      capability: CapabilityID(rawValue: "mac.accessibility.control"),
      operation: request.action.rawValue,
      resource: resource,
      details: details,
      explanation: "Allow Hex to perform this exact Accessibility action in this application."
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
      let result = try await controller.perform(request)
      return MacToolResult.accessibilityAction(result, callID: call.id)
    } catch {
      await authorizationLedger.remove(callID: call.id, runID: context.runID)
      return try MacToolResult.failure(error, callID: call.id)
    }
  }

  private func validatedRequest(_ call: ToolCall) throws -> MacAccessibilityActionRequest {
    guard call.name == definition.name else {
      throw MacToolError.invalidArguments
    }
    let arguments = try ToolCallArguments(
      call.arguments,
      allowedNames: [
        "bundle_id", "action", "path", "identifier", "role", "title", "occurrence",
        "value",
      ]
    )
    let bundleIdentifier = try MacTargetValidator.validateBundleIdentifier(
      arguments.requiredString(named: "bundle_id", maximumBytes: 255)
    )
    let rawAction = try arguments.requiredString(named: "action", maximumBytes: 32)
    guard let action = MacAccessibilityAction(rawValue: rawAction) else {
      throw MacToolError.invalidArguments
    }
    let path = try MacTargetValidator.validateElementPath(
      arguments.optionalString(named: "path", maximumBytes: 512)
    )
    let identifier = try MacTargetValidator.validatePromptText(
      arguments.optionalString(named: "identifier", maximumBytes: 1_024),
      maximumBytes: 1_024
    )
    let role = try MacTargetValidator.validatePromptText(
      arguments.optionalString(named: "role", maximumBytes: 256),
      maximumBytes: 256
    )
    let title = try MacTargetValidator.validatePromptText(
      arguments.optionalString(named: "title", maximumBytes: 1_024),
      maximumBytes: 1_024
    )
    guard path != nil || identifier != nil || role != nil || title != nil else {
      throw MacToolError.invalidArguments
    }
    let occurrence = try arguments.optionalInteger(named: "occurrence", range: 0...2_047)
    let value = try arguments.optionalString(named: "value", maximumBytes: 16_384)
    switch action {
    case .setValue:
      guard value != nil else { throw MacToolError.invalidArguments }
    case .press, .focus:
      guard value == nil else { throw MacToolError.invalidArguments }
    }
    return MacAccessibilityActionRequest(
      bundleIdentifier: bundleIdentifier,
      selector: MacAccessibilitySelector(
        path: path,
        identifier: identifier,
        role: role,
        title: title,
        occurrence: occurrence
      ),
      action: action,
      value: value
    )
  }

  private func authorizationResource(_ call: ToolCall) throws -> String {
    let data = try JSONEncoder().encode(call)
    let code = HMAC<SHA256>.authenticationCode(for: data, using: authorizationKey)
    return "mac-accessibility:hmac-sha256:" + code.map { String(format: "%02x", $0) }.joined()
  }
}
