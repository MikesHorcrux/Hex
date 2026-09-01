import Foundation

/// Injectable streaming HTTP boundary used by `OpenAIResponsesProvider`.
///
/// A successful send returns an owned response whose cancellation stops its body producer and whose
/// termination join returns only after that producer has stopped touching transport state.
public protocol OpenAIResponsesTransport: Sendable {
  func send(_ request: URLRequest) async throws -> OpenAIResponsesTransportResponse
}
