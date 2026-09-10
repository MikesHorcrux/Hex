import Foundation
import HexCore

/// Local development previews have a separate authorization surface from public web navigation.
public struct MacOpenLocalURLTool: HostTool, Sendable {
  public let definition = ToolDefinition(
    name: "mac_open_local_url",
    description: "Open a local development website in an explicitly selected macOS browser. "
      + "Use this for a running localhost preview instead of typing into browser chrome. "
      + "A fresh authorized call can reopen the preview after the user switches or closes tabs. "
      + "Only HTTP(S) URLs on literal 127.0.0.1 or [::1] are accepted. "
      + "The browser is brought forward; observe it afterward to verify the page loaded.",
    inputSchema: HostToolSchema.object(
      properties: [
        "url": HostToolSchema.string(
          "The loopback preview URL, including its server port.", maximumLength: 8_192),
        "bundle_id": HostToolSchema.string(
          "The exact installed browser bundle identifier.", maximumLength: 255),
      ], required: ["url", "bundle_id"]))

  private let controller: any MacLocalURLControlling
  private let authorizationLedger = ToolAuthorizationLedger()

  public init(controller: any MacLocalURLControlling) { self.controller = controller }

  public func authorizationRequest(for call: ToolCall, in context: ToolExecutionContext)
    async throws
    -> AuthorizationRequest
  {
    let target = try validatedTarget(call)
    try await authorizationLedger.record(call: call, runID: context.runID)
    return AuthorizationRequest(
      runID: context.runID, toolCallID: call.id,
      capability: CapabilityID(rawValue: "mac.application.control"),
      operation: "open-local-preview",
      resource: "bundle:\(target.bundleIdentifier)|\(target.url.absoluteString)",
      details: [
        "bundle_id": .string(target.bundleIdentifier), "url": .string(target.url.absoluteString),
      ],
      explanation: "Allow Hex to open this exact local preview in the selected application.")
  }

  public func execute(_ call: ToolCall, in context: ToolExecutionContext) async throws -> ToolResult
  {
    do {
      let target = try validatedTarget(call)
      try await authorizationLedger.take(call: call, runID: context.runID)
      try await controller.openLocalURL(target.url, bundleIdentifier: target.bundleIdentifier)
      return ToolResult(
        toolCallID: call.id, status: .success,
        output: .object([
          "open_requested": .boolean(true), "outcome_verified": .boolean(false),
          "url": .string(target.url.absoluteString), "bundle_id": .string(target.bundleIdentifier),
          "next_step": .string("Observe this browser to verify the local page actually loaded."),
        ]))
    } catch {
      await authorizationLedger.remove(callID: call.id, runID: context.runID)
      return try MacToolResult.failure(error, callID: call.id)
    }
  }

  private func validatedTarget(_ call: ToolCall) throws -> (url: URL, bundleIdentifier: String) {
    guard call.name == definition.name else { throw MacToolError.invalidArguments }
    let arguments = try ToolCallArguments(call.arguments, allowedNames: ["url", "bundle_id"])
    let raw = try arguments.requiredString(named: "url", maximumBytes: 8_192)
    guard !raw.contains("\\"),
      !raw.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
      let components = URLComponents(string: raw),
      components.scheme == "http" || components.scheme == "https",
      let host = components.host, ["127.0.0.1", "::1", "[::1]"].contains(host),
      components.user == nil, components.password == nil,
      components.port.map({ (1...65_535).contains($0) }) ?? true,
      let url = components.url
    else { throw MacToolError.invalidArguments }
    let bundle = try MacTargetValidator.validateBundleIdentifier(
      arguments.requiredString(named: "bundle_id", maximumBytes: 255))
    return (url, bundle)
  }
}
