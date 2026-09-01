import Foundation
import HexCapabilities
import HexCore
import Testing

@Suite("Web tools")
struct WebToolTests {
  @Test
  func fetchSanitizesHTMLAndCannotBeRetargetedAfterAuthorization() async throws {
    let pageURL = try #require(URL(string: "https://example.com/page"))
    let fetcher = Fetcher(
      response: WebFetchResponse(
        url: pageURL,
        statusCode: 200,
        contentType: "text/html; charset=utf-8",
        body: Data("<h1>Hello</h1><script>steal()</script><p>World</p>".utf8),
        isTruncated: false
      )
    )
    let tool = WebFetchTool(fetcher: fetcher)
    let context = ToolExecutionContext(runID: AgentRunID())
    let call = ToolCall(
      id: ToolCallID(rawValue: "web-fetch"),
      name: "web_fetch",
      arguments: ["url": .string(pageURL.absoluteString)]
    )

    let request = try await tool.authorizationRequest(for: call, in: context)
    #expect(request.resource == pageURL.absoluteString)
    let retargeted = ToolCall(
      id: call.id,
      name: call.name,
      arguments: ["url": .string("https://example.org/other")]
    )
    let rejected = try await tool.execute(retargeted, in: context)
    #expect(rejected.status == .failure)
    #expect(
      rejected.output == .object(["error": .string("authorization_state_unavailable")])
    )

    _ = try await tool.authorizationRequest(for: call, in: context)
    let result = try await tool.execute(call, in: context)
    #expect(result.status == .success)
    guard case .object(let output) = result.output else {
      Issue.record("Expected an object result.")
      return
    }
    #expect(output["body"] == .string("Hello\nWorld"))
  }

  @Test
  func searchReturnsBoundedHTTPSResultsFromTheProviderResponse() async throws {
    let endpoint = try #require(URL(string: "https://html.duckduckgo.com/html/"))
    let html = """
      <div class="result">
        <a class="result__a" href="https://developer.apple.com/swift/">Swift &amp; Apple</a>
        <a class="result__snippet" href="https://developer.apple.com/swift/">Build with <b>Swift</b>.</a>
      </div>
      """
    let fetcher = Fetcher(
      response: WebFetchResponse(
        url: endpoint,
        statusCode: 200,
        contentType: "text/html",
        body: Data(html.utf8),
        isTruncated: false
      )
    )
    let tool = WebSearchTool(fetcher: fetcher)
    let context = ToolExecutionContext(runID: AgentRunID())
    let call = ToolCall(
      id: ToolCallID(rawValue: "web-search"),
      name: "web_search",
      arguments: [
        "query": .string("Swift concurrency"),
        "max_results": .integer(3),
      ]
    )

    _ = try await tool.authorizationRequest(for: call, in: context)
    let result = try await tool.execute(call, in: context)

    #expect(result.status == .success)
    guard case .object(let output) = result.output,
      case .array(let results) = output["results"]
    else {
      Issue.record("Expected search results.")
      return
    }
    #expect(results.count == 1)
    #expect(
      results.first
        == .object([
          "title": .string("Swift & Apple"),
          "url": .string("https://developer.apple.com/swift/"),
          "snippet": .string("Build with Swift."),
        ])
    )
  }

  @Test
  func rejectsLocalAndCredentialBearingURLsBeforeAuthorization() async throws {
    let fallbackURL = try #require(URL(string: "https://example.com/"))
    let tool = WebFetchTool(
      fetcher: Fetcher(
        response: WebFetchResponse(
          url: fallbackURL,
          statusCode: 200,
          contentType: "text/plain",
          body: Data(),
          isTruncated: false
        )
      )
    )
    let context = ToolExecutionContext(runID: AgentRunID())

    for value in ["https://localhost/admin", "https://user:pass@example.com/"] {
      await #expect(throws: WebToolError.self) {
        _ = try await tool.authorizationRequest(
          for: ToolCall(
            id: ToolCallID(),
            name: "web_fetch",
            arguments: ["url": .string(value)]
          ),
          in: context
        )
      }
    }
  }

  private actor Fetcher: WebFetching {
    private let response: WebFetchResponse

    init(response: WebFetchResponse) {
      self.response = response
    }

    func fetch(_ request: WebFetchRequest) async throws -> WebFetchResponse {
      response
    }
  }
}
