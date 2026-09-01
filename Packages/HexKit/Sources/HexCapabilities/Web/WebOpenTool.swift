import Foundation
import HexCore

public struct WebOpenTool: HostTool, Sendable {
  public let definition = ToolDefinition(
    name: "web_open",
    description:
      "Open one public HTTPS URL in the user's default browser. This is a visible external action.",
    inputSchema: HostToolSchema.object(
      properties: [
        "url": HostToolSchema.string(
          "A public HTTPS URL. Local, private, credential-bearing, and custom-port URLs are rejected.",
          maximumLength: 8_192
        )
      ],
      required: ["url"]
    )
  )

  private let addressValidator: any WebAddressValidating
  private let applicationController: any MacApplicationControlling
  private let authorizationLedger = ToolAuthorizationLedger()

  public init(
    addressValidator: any WebAddressValidating,
    applicationController: any MacApplicationControlling
  ) {
    self.addressValidator = addressValidator
    self.applicationController = applicationController
  }

  public func authorizationRequest(
    for call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> AuthorizationRequest {
    let url = try validatedURL(call)
    try await authorizationLedger.record(call: call, runID: context.runID)
    return AuthorizationRequest(
      runID: context.runID,
      toolCallID: call.id,
      capability: CapabilityID(rawValue: "browser.open"),
      operation: "open-url",
      resource: url.absoluteString,
      details: ["url": .string(url.absoluteString)],
      explanation: "Allow Hex to open this exact public HTTPS URL in the default browser."
    )
  }

  public func execute(
    _ call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> ToolResult {
    do {
      let url = try validatedURL(call)
      try await authorizationLedger.take(call: call, runID: context.runID)
      try await addressValidator.validate(url)
      try await applicationController.openURL(url)
      return MacToolResult.openedURL(url, callID: call.id)
    } catch {
      await authorizationLedger.remove(callID: call.id, runID: context.runID)
      return try WebToolResult.failure(error, callID: call.id)
    }
  }

  private func validatedURL(_ call: ToolCall) throws -> URL {
    guard call.name == definition.name else {
      throw WebToolError.invalidArguments
    }
    let arguments = try ToolCallArguments(call.arguments, allowedNames: ["url"])
    return try WebURLPolicy.validatedURL(
      from: arguments.requiredString(named: "url", maximumBytes: 8_192)
    )
  }
}
