import HexCore

/// Fail-closed authorization route used while a resident gateway's decision IPC is unavailable.
/// Authorization prompts may still be displayed from replayed events, but a choice is never
/// reported as accepted unless the gateway acknowledges it.
struct HexUnavailableAuthorizationDecisionTransport: HexAuthorizationDecisionSubmitting {
  enum TransportError: Error, Equatable, LocalizedError, Sendable {
    case unavailable

    var errorDescription: String? {
      "The resident gateway authorization channel is not available yet."
    }
  }

  func submit(
    _ request: AuthorizationRequest,
    choice: AuthorizationDecisionChoice
  ) async throws {
    _ = request
    _ = choice
    throw TransportError.unavailable
  }
}
