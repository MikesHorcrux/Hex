/// Decides whether an operation may proceed. Denial is ordinary control flow, not an infrastructure
/// error. Implementations must propagate task cancellation and `CancellationError` without wrapping.
/// `endRun` must promptly discard run-scoped authority and must not fail; the runtime invokes it once
/// whenever an owned run exits, including cancellation and failure.
public protocol AuthorizationProvider: Sendable {
  func authorize(_ request: AuthorizationRequest) async throws -> AuthorizationDecision

  func endRun(_ runID: AgentRunID) async
}

extension AuthorizationProvider {
  public func endRun(_ runID: AgentRunID) async {}
}
