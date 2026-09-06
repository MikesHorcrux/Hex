/// Decides whether an operation may proceed. Denial is ordinary control flow, not an infrastructure
/// error. Implementations must propagate task cancellation and `CancellationError` without wrapping.
/// `endRun` must promptly discard run-scoped authority and must not fail; the runtime invokes it once
/// whenever an owned run exits, including cancellation and failure.
public protocol AuthorizationProvider: Sendable {
  /// Pins a host-supplied approval choice before this run can execute any tools. Nil preserves the
  /// provider's configured policy; explicit choices must be honored or rejected, never ignored.
  func beginRun(_ runID: AgentRunID, authorizationMode: HexAuthorizationMode?) async throws

  func authorize(_ request: AuthorizationRequest) async throws -> AuthorizationDecision

  func endRun(_ runID: AgentRunID) async
}

extension AuthorizationProvider {
  public func beginRun(_ runID: AgentRunID, authorizationMode: HexAuthorizationMode?) async throws {
    try Task.checkCancellation()
    guard authorizationMode == nil else { throw AuthorizationPolicyError.unsupportedOverride }
  }

  public func endRun(_ runID: AgentRunID) async {}
}
