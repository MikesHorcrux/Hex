import HexCore

/// App-owned seam for returning an operator's authorization choice to the process that owns the
/// gateway broker. A resident implementation can later encode this call over HexIPC; the app does
/// not recreate or own the resident broker.
nonisolated protocol HexAuthorizationDecisionSubmitting: Sendable {
  func submit(
    _ request: AuthorizationRequest,
    choice: AuthorizationDecisionChoice
  ) async throws
}
