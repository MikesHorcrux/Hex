import HexCore

enum WebToolResult {
  static func fetch(
    response: WebFetchResponse,
    text: String,
    callID: ToolCallID
  ) -> ToolResult {
    var output: [String: JSONValue] = [
      "url": .string(response.url.absoluteString),
      "status_code": .integer(Int64(response.statusCode)),
      "body": .string(text),
      "is_truncated": .boolean(response.isTruncated),
    ]
    if let contentType = response.contentType {
      output["content_type"] = .string(contentType)
    }
    if let redirectURL = response.redirectURL {
      output["redirect_url"] = .string(redirectURL.absoluteString)
      output["redirect_followed"] = .boolean(false)
    }
    return ToolResult(toolCallID: callID, status: .success, output: .object(output))
  }

  static func search(
    query: String,
    results: [WebSearchResult],
    callID: ToolCallID
  ) -> ToolResult {
    ToolResult(
      toolCallID: callID,
      status: .success,
      output: .object([
        "query": .string(query),
        "provider": .string("duckduckgo_html"),
        "results": .array(
          results.map { result in
            .object([
              "title": .string(result.title),
              "url": .string(result.url.absoluteString),
              "snippet": .string(result.snippet),
            ])
          }),
      ])
    )
  }

  static func failure(_ error: any Error, callID: ToolCallID) throws -> ToolResult {
    if error is CancellationError {
      throw CancellationError()
    }
    let code: String
    switch error {
    case ToolCallArgumentsError.invalidArguments, WebToolError.invalidArguments:
      code = "invalid_arguments"
    case ToolAuthorizationLedgerError.authorizationRequired,
      WebToolError.authorizationRequired:
      code = "authorization_required"
    case ToolAuthorizationLedgerError.capacityExceeded,
      ToolAuthorizationLedgerError.conflictingRequest,
      WebToolError.authorizationStateUnavailable:
      code = "authorization_state_unavailable"
    case WebToolError.urlNotAllowed:
      code = "url_not_allowed"
    case WebToolError.hostResolutionFailed:
      code = "host_resolution_failed"
    case WebToolError.privateAddressRejected:
      code = "private_address_rejected"
    case WebToolError.networkFailure:
      code = "network_failure"
    case WebToolError.invalidResponse:
      code = "invalid_response"
    case WebToolError.unsupportedContentType:
      code = "unsupported_content_type"
    case WebToolError.invalidTextEncoding:
      code = "invalid_text_encoding"
    case WebToolError.searchResponseInvalid:
      code = "search_response_invalid"
    case WebToolError.openURLFailed, MacToolError.openURLFailed:
      code = "open_url_failed"
    default:
      throw error
    }
    return ToolResult(
      toolCallID: callID,
      status: .failure,
      output: .object(["error": .string(code)])
    )
  }
}
