/// Decides whether an operation may proceed. Denial is ordinary control flow, not an infrastructure
/// error. Implementations must propagate task cancellation and `CancellationError` without wrapping.
public protocol AuthorizationProvider: Sendable {
  func authorize(_ request: AuthorizationRequest) async throws -> AuthorizationDecision
}
