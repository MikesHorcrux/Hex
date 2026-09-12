import Foundation

/// The caller owns the task lifetime; models own which state each refresh reads.
@MainActor
struct AgentWorkspaceRefreshLoop {
  let wait: () async throws -> Void

  init(wait: @escaping () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }) {
    self.wait = wait
  }

  func run(refresh: () async throws -> Void) async {
    while !Task.isCancelled {
      do {
        try await refresh()
        guard !Task.isCancelled else { return }
        try await wait()
      } catch { return }
    }
  }
}
