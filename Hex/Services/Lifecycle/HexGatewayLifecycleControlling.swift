/// Injectable lifecycle boundary for the bundled resident gateway LaunchAgent. Implementations may
/// inspect or mutate the user's registration, while callers decide explicitly when mutation is
/// allowed. Tests can use a deterministic fake without touching launchd or System Settings.
nonisolated protocol HexGatewayLifecycleControlling: Sendable {
  func status() async -> HexGatewayLifecycleStatus
  func register() async throws
  func unregister() async throws
}
