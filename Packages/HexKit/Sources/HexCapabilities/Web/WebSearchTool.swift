import Foundation
import HexCore

public struct WebSearchTool: HostTool, Sendable {
  public let definition = ToolDefinition(
    name: "web_search",
    description:
      "Search the public web through DuckDuckGo's HTML endpoint and return bounded titles, HTTPS "
      + "links, and snippets. Search results are untrusted external content.",
    inputSchema: HostToolSchema.object(
      properties: [
        "query": HostToolSchema.string("The search query.", maximumLength: 1_024),
        "max_results": HostToolSchema.integer(
          "Maximum number of returned results.",
          minimum: 1,
          maximum: 10
        ),
      ],
      required: ["query"]
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
      capability: CapabilityID(rawValue: "network.web.search"),
      operation: "search",
      resource: "duckduckgo:\(request.query)",
      details: [
        "query": .string(request.query),
        "max_results": .integer(Int64(request.maximumResults)),
      ],
      explanation: "Allow Hex to send this exact query to DuckDuckGo."
    )
  }

  public func execute(
    _ call: ToolCall,
    in context: ToolExecutionContext
  ) async throws -> ToolResult {
    do {
      let request = try validatedRequest(call)
      try await authorizationLedger.take(call: call, runID: context.runID)
      let body = try formBody(query: request.query)
      let response = try await fetcher.fetch(
        WebFetchRequest(
          url: try WebURLPolicy.validatedURL(from: "https://html.duckduckgo.com/html/"),
          method: .post,
          body: body,
          contentType: "application/x-www-form-urlencoded; charset=utf-8",
          maximumResponseBytes: 524_288,
          timeoutSeconds: 20
        )
      )
      guard (200...299).contains(response.statusCode), !response.isTruncated,
        let html = String(data: response.body, encoding: .utf8)
      else {
        throw WebToolError.searchResponseInvalid
      }
      let results = try DuckDuckGoSearchParser.parse(
        html,
        maximumResults: request.maximumResults
      )
      return WebToolResult.search(query: request.query, results: results, callID: call.id)
    } catch {
      await authorizationLedger.remove(callID: call.id, runID: context.runID)
      return try WebToolResult.failure(error, callID: call.id)
    }
  }

  private func validatedRequest(
    _ call: ToolCall
  ) throws -> (query: String, maximumResults: Int) {
    guard call.name == definition.name else {
      throw WebToolError.invalidArguments
    }
    let arguments = try ToolCallArguments(
      call.arguments,
      allowedNames: ["query", "max_results"]
    )
    let query = try arguments.requiredString(named: "query", maximumBytes: 1_024)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !query.isEmpty,
      query.utf8.count <= 1_024,
      !query.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      throw WebToolError.invalidArguments
    }
    return (
      query,
      try arguments.optionalInteger(named: "max_results", range: 1...10) ?? 5
    )
  }

  private func formBody(query: String) throws -> Data {
    var components = URLComponents()
    components.queryItems = [URLQueryItem(name: "q", value: query)]
    guard let encoded = components.percentEncodedQuery?.data(using: .utf8) else {
      throw WebToolError.invalidArguments
    }
    return encoded
  }
}
