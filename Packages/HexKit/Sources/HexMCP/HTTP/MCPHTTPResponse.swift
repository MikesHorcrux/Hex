import Foundation

struct MCPHTTPResponse: Sendable {
  let statusCode: Int
  let headers: [String: String]
  let body: Data
  let finalURL: URL

  var isEventStream: Bool {
    headers["content-type"]?.split(separator: ";", maxSplits: 1).first?
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "text/event-stream"
  }
}
