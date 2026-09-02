import Foundation

protocol MCPHTTPTransport: Sendable {
  func send(
    _ request: URLRequest,
    maximumResponseBytes: Int
  ) async throws -> MCPHTTPResponse
}
