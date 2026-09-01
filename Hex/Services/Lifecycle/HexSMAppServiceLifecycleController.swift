@preconcurrency import ServiceManagement

/// Real macOS lifecycle adapter for the resident gateway LaunchAgent. Constructing this adapter is
/// inert; registration and unregistration occur only when the injected controller is explicitly
/// called by a user-facing action.
actor HexSMAppServiceLifecycleController: HexGatewayLifecycleControlling,
  HexLoginItemsSettingsOpening
{
  static let gatewayPlistName = "com.lunarmothstudios.hex.gateway.plist"

  private let service: SMAppService

  init(
    plistName: String = HexSMAppServiceLifecycleController.gatewayPlistName
  ) {
    service = SMAppService.agent(plistName: plistName)
  }

  func status() async -> HexGatewayLifecycleStatus {
    switch service.status {
    case .enabled:
      .enabled
    case .notRegistered:
      .notRegistered
    case .requiresApproval:
      .requiresApproval
    case .notFound:
      .notFound
    @unknown default:
      .unavailable
    }
  }

  func register() async throws {
    try service.register()
  }

  func unregister() async throws {
    try await service.unregister()
  }

  func openLoginItemsSettings() async {
    SMAppService.openSystemSettingsLoginItems()
  }
}
