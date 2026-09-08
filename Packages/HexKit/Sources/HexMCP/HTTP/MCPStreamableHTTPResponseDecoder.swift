import Foundation
import HexCore

enum MCPStreamableHTTPResponseDecoder {
  static func decode(
    _ response: MCPHTTPResponse,
    maximumMessageBytes: Int,
    maximumSSEEvents: Int
  ) throws -> [JSONValue] {
    guard response.body.count <= maximumMessageBytes else {
      throw MCPClientSessionError.limitExceeded
    }
    guard
      let rawContentType = response.headers["content-type"],
      let mediaType = rawContentType.split(separator: ";", maxSplits: 1).first?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    else {
      throw MCPClientSessionError.protocolViolation
    }
    switch mediaType {
    case "application/json":
      guard !response.body.isEmpty else {
        throw MCPClientSessionError.protocolViolation
      }
      try MCPJSONStructuralPreflight.validateObjectRoot(response.body)
      do {
        return [try JSONDecoder().decode(JSONValue.self, from: response.body)]
      } catch {
        throw MCPClientSessionError.protocolViolation
      }
    case "text/event-stream":
      return try MCPSSEMessageDecoder.decode(
        response.body,
        maximumEvents: maximumSSEEvents,
        maximumMessageBytes: maximumMessageBytes
      )
    default:
      throw MCPClientSessionError.protocolViolation
    }
  }
}
