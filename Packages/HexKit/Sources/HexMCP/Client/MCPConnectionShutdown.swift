import Foundation

final class MCPConnectionShutdown: Sendable {
  let id: UUID
  let generation: UInt64
  let completion: Task<Void, Never>

  init(
    id: UUID,
    generation: UInt64,
    completion: Task<Void, Never>
  ) {
    self.id = id
    self.generation = generation
    self.completion = completion
  }
}
