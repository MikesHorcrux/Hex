import Foundation

struct JSONPersonalMemoryStoreSnapshot: Codable, Sendable {
  let schemaVersion: Int
  let records: [PersonalMemoryRecord]
}
