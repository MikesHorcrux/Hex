import Foundation

struct MCPWriteOperation: Sendable {
  let generation: UInt64
  let data: Data
  let continuation: CheckedContinuation<Void, any Error>
}
