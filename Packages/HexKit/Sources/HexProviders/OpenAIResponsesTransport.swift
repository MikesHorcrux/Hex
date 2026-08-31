import Foundation

/// Injectable streaming HTTP boundary used by `OpenAIResponsesProvider`.
public protocol OpenAIResponsesTransport: Sendable {
  func send(_ request: URLRequest) async throws -> OpenAIResponsesTransportResponse
}
