import HexCore

actor ScriptedAuthorizationProvider: AuthorizationProvider {
  private var mode: AuthorizationProviderMode
  private var capturedRequests: [AuthorizationRequest] = []

  init(mode: AuthorizationProviderMode = .decisions([])) {
    self.mode = mode
  }

  func authorize(_ request: AuthorizationRequest) async throws -> AuthorizationDecision {
    capturedRequests.append(request)
    switch mode {
    case .decisions(var decisions):
      let decision = decisions.isEmpty ? .allow : decisions.removeFirst()
      mode = .decisions(decisions)
      return decision
    case .throwing:
      throw ScriptedAuthorizationProviderError.authorization
    case .suspend:
      try await Task.sleep(for: .seconds(60))
      return .allow
    }
  }

  func requests() -> [AuthorizationRequest] {
    capturedRequests
  }
}
