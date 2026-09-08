import HexCore

public struct WebFetchTool: HostTool, Sendable {
  public let definition = ToolDefinition(
    name: "web_fetch",
    description:
      "Fetch bounded text from one public HTTPS URL. Cookies are disabled and redirects are never "
      + "followed silently; a safe redirect target is returned for a separately authorized call.",
    inputSchema: HostToolSchema.object(
      properties: [
        "url": HostToolSchema.string(
          "A public HTTPS URL. Local, private, credential-bearing, and custom-port URLs are rejected.",
          maximumLength: 8_192
        ),
        "max_bytes": HostToolSchema.integer(
          "Maximum response bytes retained before truncation.",
          minimum: 1_024,
          maximum: 1_048_576
        ),
        "timeout_seconds": HostToolSchema.integer(
          "Maximum request time.",
          minimum: 1,
          maximum: 60
        ),
      ],
      required: ["url"]
    )
  )

  private let fetcher: any WebFetching
  private let authorizationLedger = ToolAuthorizationLedger()

  public init(fetcher: any WebFetching) {
    self.fetcher = fetcher
  }

  public func authorizationRequest(
    for call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> AuthorizationRequest {
    let request = try validatedRequest(call)
    try await authorizationLedger.record(call: call, runID: context.runID)
    return AuthorizationRequest(
      runID: context.runID,
      toolCallID: call.id,
      capability: CapabilityID(rawValue: "network.web.read"),
      operation: "fetch",
      resource: request.url.absoluteString,
      details: [
        "url": .string(request.url.absoluteString),
        "max_bytes": .integer(Int64(request.maximumResponseBytes)),
        "timeout_seconds": .integer(Int64(request.timeoutSeconds)),
        "redirects": .string("return-only"),
      ],
      explanation: "Allow Hex to read bounded text from this exact public HTTPS URL."
    )
  }

  public func execute(
    _ call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> ToolResult {
    do {
      let request = try validatedRequest(call)
      try await authorizationLedger.take(call: call, runID: context.runID)
      let response = try await fetcher.fetch(request)
      let text = try WebContentExtractor.text(from: response)
      return WebToolResult.fetch(response: response, text: text, callID: call.id)
    } catch {
      await authorizationLedger.remove(callID: call.id, runID: context.runID)
      return try WebToolResult.failure(error, callID: call.id)
    }
  }

  private func validatedRequest(_ call: ToolCall) throws -> WebFetchRequest {
    guard call.name == definition.name else {
      throw WebToolError.invalidArguments
    }
    let arguments = try ToolCallArguments(
      call.arguments,
      allowedNames: ["url", "max_bytes", "timeout_seconds"]
    )
    let url = try WebURLPolicy.validatedURL(
      from: arguments.requiredString(named: "url", maximumBytes: 8_192)
    )
    return WebFetchRequest(
      url: url,
      maximumResponseBytes: try arguments.optionalInteger(
        named: "max_bytes",
        range: 1_024...1_048_576
      ) ?? 262_144,
      timeoutSeconds: try arguments.optionalInteger(
        named: "timeout_seconds",
        range: 1...60
      ) ?? 20
    )
  }
}
