import HexCore

/// Preserves the center's policy and grant lifecycle while keeping a scheduled run classified as
/// background until its actual runtime ends, even if its observer disconnects first.
public struct HexHeartbeatAuthorizationProvider: AuthorizationProvider {
  private let base: any AuthorizationProvider
  private let policy: HexHeartbeatAuthorizationPolicy

  public init(base: any AuthorizationProvider, policy: HexHeartbeatAuthorizationPolicy) {
    self.base = base
    self.policy = policy
  }

  public func authorize(_ request: AuthorizationRequest) async throws -> AuthorizationDecision {
    try await base.authorize(request)
  }

  public func beginRun(_ runID: AgentRunID, authorizationMode: HexAuthorizationMode?) async throws {
    try await base.beginRun(runID, authorizationMode: authorizationMode)
  }

  public func endRun(_ runID: AgentRunID) async {
    await base.endRun(runID)
    await policy.runtimeDidEnd(runID)
  }
}
