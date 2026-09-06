import HexIPC

/// App-facing boundary for screen-control permission checks performed by the resident gateway.
/// Keeping this separate from installation ensures macOS attributes every request to the same
/// always-on process that later launches the screen-control runtime.
nonisolated protocol HexScreenControlPermissionServicing: Sendable {
  func screenControlPermissionStatus() async throws -> GatewayScreenControlPermissionStatus
  func requestScreenControlPermission() async throws -> GatewayScreenControlPermissionStatus
}
