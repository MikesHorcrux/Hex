import Foundation

struct MCPWriteOperation: Sendable {
  let id: UUID
  let generation: UInt64
  let data: Data
  let deadlineUptimeNanoseconds: UInt64
  let continuation: CheckedContinuation<Void, any Error>
}
