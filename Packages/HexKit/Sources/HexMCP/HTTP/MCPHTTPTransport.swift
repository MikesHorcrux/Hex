import Foundation
import HexCore

protocol MCPHTTPTransport: Sendable {
  func send(
    _ request: URLRequest,
    maximumResponseBytes: Int
  ) async throws -> MCPHTTPResponse

  func send(
    _ request: URLRequest,
    maximumResponseBytes: Int,
    maximumSSEEvents: Int,
    receiveSSEMessage: @escaping @Sendable (JSONValue, [String: String]) async throws -> Bool
  ) async throws -> MCPHTTPResponse
}

extension MCPHTTPTransport {
  /// Complete-response transports remain useful as deterministic fixtures.
  func send(
    _ request: URLRequest,
    maximumResponseBytes: Int,
    maximumSSEEvents: Int,
    receiveSSEMessage: @escaping @Sendable (JSONValue, [String: String]) async throws -> Bool
  ) async throws -> MCPHTTPResponse {
    let response = try await send(request, maximumResponseBytes: maximumResponseBytes)
    if response.statusCode == 200, response.isEventStream {
      let messages = try MCPSSEMessageDecoder.decode(
        response.body, maximumEvents: maximumSSEEvents,
        maximumMessageBytes: maximumResponseBytes)
      for message in messages {
        if try await receiveSSEMessage(message, response.headers) { break }
      }
    }
    return response
  }
}
