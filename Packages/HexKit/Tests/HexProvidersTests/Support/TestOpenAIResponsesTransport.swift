import Foundation

@testable import HexProviders

actor TestOpenAIResponsesTransport: OpenAIResponsesTransport {
  private var queuedResponses: [OpenAIResponsesTransportResponse]
  private var sentRequests: [URLRequest] = []

  init(responses: [OpenAIResponsesTransportResponse]) {
    queuedResponses = responses
  }

  func send(_ request: URLRequest) async throws -> OpenAIResponsesTransportResponse {
    sentRequests.append(request)
    guard !queuedResponses.isEmpty else {
      throw URLError(.badServerResponse)
    }
    return queuedResponses.removeFirst()
  }

  func requests() -> [URLRequest] {
    sentRequests
  }
}
