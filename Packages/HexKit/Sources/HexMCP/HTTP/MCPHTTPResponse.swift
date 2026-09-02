import Foundation

struct MCPHTTPResponse: Sendable {
  let statusCode: Int
  let headers: [String: String]
  let body: Data
  let finalURL: URL
}
