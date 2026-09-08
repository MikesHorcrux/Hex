import Foundation

struct ServerSentEvent: Sendable {
  let name: String?
  let data: Data
}
