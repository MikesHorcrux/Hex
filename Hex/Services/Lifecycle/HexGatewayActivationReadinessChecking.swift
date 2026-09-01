/// Computes whether the resident LaunchAgent can be exposed to the user.
///
/// Implementations must be read-only. In particular, a check may inspect configuration, credentials,
/// and bundle files, but it must never register or unregister the LaunchAgent.
nonisolated protocol HexGatewayActivationReadinessChecking: Sendable {
  func check() async -> HexGatewayActivationReadiness
}
