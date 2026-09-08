/// Fail-closed activation checker used by Release composition and deterministic tests.
nonisolated struct HexBlockedGatewayActivationChecker: HexGatewayActivationReadinessChecking {
  func check() async -> HexGatewayActivationReadiness {
    .blocked
  }
}
