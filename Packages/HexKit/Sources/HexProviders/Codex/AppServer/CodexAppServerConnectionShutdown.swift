import Foundation

struct CodexAppServerConnectionShutdown: Sendable {
  let id: UUID
  let generation: UInt64
  let completion: Task<Void, Never>
}
