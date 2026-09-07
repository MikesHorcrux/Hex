import AppKit
import HexPersistence
import HexPersonality
import SwiftUI

@main
struct HexApp: App {
  @State private var workspace: AgentWorkspaceModel
  @State private var residentGateway: HexResidentGatewayModel
  @State private var startAtLogin: HexStartAtLoginModel
  @State private var residentSetup: HexResidentSetupModel
  @State private var toolConnections: HexToolConnectionsModel
  @State private var heartbeatManagement: HexHeartbeatManagementModel
  @State private var personalitySettings: HexPersonalitySettingsModel
  @State private var inferenceBackendSettings: HexInferenceBackendSettingsModel
  @State private var accessibilityPermission: HexAccessibilityPermissionModel
  private let route: HexGatewayRoute
  private let isVerificationOnlyLaunch: Bool
  private let suppressOnboarding: Bool

  init() {
    // Hosted unit tests must never resolve the user's settings, credentials or resident service.
    // Live integration tests explicitly construct their own authorized client instead.
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
      || Self.isVerificationOnlyLaunch(arguments: CommandLine.arguments)
    {
      self.init(
        personalityService: HexUnavailablePersonalityService(),
        isVerificationOnlyLaunch: true,
        suppressOnboarding: true
      )
      return
    }
    let configuration = HexDeveloperConfiguration(
      environment: ProcessInfo.processInfo.environment
    )
    let client = HexLiveAgentClient(configuration: configuration)
    let initialModelID =
      configuration.gatewayRoute.isResident
      ? ""
      : configuration.modelIDForInterface
    let verificationOnlyLaunch = Self.isVerificationOnlyLaunch(arguments: CommandLine.arguments)
    let suppressOnboarding = Self.isOnboardingSuppressed(arguments: CommandLine.arguments)
    let setupDependencies = HexResidentSetupDependencies.live(for: configuration.gatewayRoute)
    let inferenceBackendDependencies =
      HexInferenceBackendSettingsDependencies.live(for: configuration.gatewayRoute)
    let composerPreferenceStore = UserDefaultsAgentComposerPreferenceStore()
    self.init(
      client: client,
      modelID: initialModelID,
      conversationStore: AgentConversationStore.live(),
      requiresConversationPersistence: true,
      composerPreferenceStore: composerPreferenceStore,
      route: configuration.gatewayRoute,
      residentGatewayController: client,
      setupDependencies: setupDependencies,
      heartbeatService: nil,
      personalityService: nil,
      personalityMemoryScope: .hex,
      inferenceBackendDependencies: inferenceBackendDependencies,
      isVerificationOnlyLaunch: verificationOnlyLaunch,
      suppressOnboarding: suppressOnboarding
    )
  }

  init(
    client: any HexAgentClient = PreviewHexAgentClient(),
    modelID: String = "preview",
    conversationStore: AgentConversationStore? = nil,
    requiresConversationPersistence: Bool = false,
    composerPreferenceStore: (any AgentComposerPreferenceStoring)? = nil,
    route: HexGatewayRoute = .residentXPC(),
    residentGatewayController: any HexResidentGatewayControlling =
      HexUnavailableResidentGatewayController(),
    setupDependencies: HexResidentSetupDependencies = .blocked,
    heartbeatService: (any HexHeartbeatManaging)? = nil,
    personalityService: (any HexPersonalityServicing)? = nil,
    personalityMemoryScope: PersonalMemoryScope = .hex,
    inferenceBackendDependencies: HexInferenceBackendSettingsDependencies = .blocked,
    accessibilityPermissionService: (any HexAccessibilityPermissionServicing)? = nil,
    screenControlPermissionService: (any HexScreenControlPermissionServicing)? = nil,
    lifecycleController: any HexGatewayLifecycleControlling =
      HexSMAppServiceLifecycleController(),
    isVerificationOnlyLaunch: Bool = false,
    suppressOnboarding: Bool = false
  ) {
    self.route = route
    self.isVerificationOnlyLaunch = isVerificationOnlyLaunch
    self.suppressOnboarding = suppressOnboarding
    let workspace = AgentWorkspaceModel(
      client: client,
      modelID: modelID,
      conversationStore: conversationStore,
      requiresConversationPersistence: requiresConversationPersistence,
      composerPreferenceStore: composerPreferenceStore
    )
    _workspace = State(initialValue: workspace)
    _toolConnections = State(
      initialValue: HexToolConnectionsModel(
        service: route.isResident ? client as? any HexToolServerHealthServicing : nil))
    _residentGateway = State(
      initialValue: HexResidentGatewayModel(controller: residentGatewayController)
    )
    let startAtLogin = HexStartAtLoginModel(
      controller: lifecycleController,
      readinessChecker: setupDependencies.readinessChecker,
      connectionResetter: client as? any HexResidentGatewayConnectionResetting,
      onConnectionReset: { [weak workspace] in workspace?.markGatewayDisconnected() },
      onBecameReady: { [weak workspace] in
        guard !isVerificationOnlyLaunch, route.isResident else { return }
        await workspace?.residentGatewayBecameReady()
      }
    )
    _startAtLogin = State(initialValue: startAtLogin)
    let resolvedHeartbeatService: any HexHeartbeatManaging
    if let heartbeatService {
      resolvedHeartbeatService = heartbeatService
    } else if route.isResident, let heartbeatClient = client as? any HexHeartbeatManaging {
      resolvedHeartbeatService = heartbeatClient
    } else {
      resolvedHeartbeatService = HexUnavailableHeartbeatService()
    }
    _heartbeatManagement = State(
      initialValue: HexHeartbeatManagementModel(service: resolvedHeartbeatService, client: client)
    )

    let resolvedPersonalityService = personalityService ?? Self.livePersonalityService()
    _personalitySettings = State(
      initialValue: HexPersonalitySettingsModel(
        service: resolvedPersonalityService,
        scope: personalityMemoryScope
      )
    )

    _inferenceBackendSettings = State(
      initialValue: HexInferenceBackendSettingsModel(
        settingsStore: inferenceBackendDependencies.settingsStore,
        secretStore: inferenceBackendDependencies.secretStore,
        chatGPTAuthorizationManager:
          inferenceBackendDependencies.chatGPTAuthorizationManager,
        localModelInstaller: inferenceBackendDependencies.localModelInstaller,
        configurationReloader: startAtLogin
      )
    )

    let resolvedAccessibilityPermissionService: any HexAccessibilityPermissionServicing
    if let accessibilityPermissionService {
      resolvedAccessibilityPermissionService = accessibilityPermissionService
    } else if route.isResident,
      let livePermissionService = client as? any HexAccessibilityPermissionServicing
    {
      resolvedAccessibilityPermissionService = livePermissionService
    } else {
      resolvedAccessibilityPermissionService = HexUnavailableAccessibilityPermissionService()
    }
    _accessibilityPermission = State(
      initialValue: HexAccessibilityPermissionModel(
        service: resolvedAccessibilityPermissionService
      )
    )

    let resolvedScreenControlPermissionService: any HexScreenControlPermissionServicing
    if let screenControlPermissionService {
      resolvedScreenControlPermissionService = screenControlPermissionService
    } else if route.isResident,
      let livePermissionService = client as? any HexScreenControlPermissionServicing
    {
      resolvedScreenControlPermissionService = livePermissionService
    } else {
      resolvedScreenControlPermissionService = HexUnavailableScreenControlPermissionService()
    }
    _residentSetup = State(
      initialValue: HexResidentSetupModel(
        initialModelID: modelID,
        settingsStore: setupDependencies.settingsStore,
        secretStore: setupDependencies.secretStore,
        managedToolLayout: setupDependencies.managedToolLayout,
        managedToolInstaller: setupDependencies.managedToolInstaller,
        screenControlPermissionService: resolvedScreenControlPermissionService,
        permissionManagementService: client as? any HexPermissionManaging,
        configurationReloader: startAtLogin
      )
    )
  }

  var body: some Scene {
    Window("Hex", id: "main") {
      HexRootView(
        workspace: workspace,
        residentSetup: residentSetup,
        inference: inferenceBackendSettings,
        personality: personalitySettings,
        startAtLogin: startAtLogin,
        accessibilityPermission: accessibilityPermission,
        suppressOnboarding: suppressOnboarding,
        suppressAutomaticConnection: isVerificationOnlyLaunch
      )
    }
    .defaultSize(width: 1120, height: 760)

    Settings {
      HexSettingsView(
        workspace: workspace,
        residentSetup: residentSetup,
        toolConnections: toolConnections,
        inference: inferenceBackendSettings,
        heartbeat: heartbeatManagement,
        personality: personalitySettings,
        startAtLogin: startAtLogin,
        accessibilityPermission: accessibilityPermission,
        route: route,
        suppressAutomaticRefresh: isVerificationOnlyLaunch
      )
      .onChange(of: residentSetup.saveGeneration) { _, _ in
        guard !isVerificationOnlyLaunch else { return }
        Task {
          await startAtLogin.refresh()
        }
      }
    }

    MenuBarExtra {
      HexMenuBarView(
        workspace: workspace,
        gateway: residentGateway,
        startAtLogin: startAtLogin,
        route: route,
        suppressAutomaticRefresh: isVerificationOnlyLaunch,
        onQuitHexUI: {
          // This only terminates the control surface. The resident LaunchAgent is a separate
          // process and is intentionally not stopped by closing or quitting the app UI.
          NSApplication.shared.terminate(nil)
        }
      )
    } label: {
      Image(systemName: menuBarSymbol)
        .accessibilityLabel("Hex gateway")
    }
    .menuBarExtraStyle(.menu)
  }

  private var menuBarSymbol: String {
    switch residentGateway.status {
    case .paused:
      "pause.circle.fill"
    case .active:
      "bolt.circle.fill"
    case .idle:
      "checkmark.circle.fill"
    case .unavailable:
      "exclamationmark.circle"
    }
  }

  nonisolated static func isVerificationOnlyLaunch(arguments: [String]) -> Bool {
    arguments.contains("--hex-verify-no-connect")
  }

  nonisolated static func isOnboardingSuppressed(arguments: [String]) -> Bool {
    arguments.contains("--hex-verify-no-connect") || arguments.contains("--hex-skip-onboarding")
  }

  private static func livePersonalityService() -> any HexPersonalityServicing {
    guard let paths = try? HexResidentDataPaths.live(),
      let profileStore = try? JSONPersonalityProfileStore(
        fileURL: paths.personalityProfileURL
      ),
      let memoryStore = try? JSONPersonalMemoryStore(fileURL: paths.personalMemoryURL),
      let service = try? HexPersonalityService(
        profileStore: profileStore,
        memoryStore: memoryStore
      )
    else {
      return HexUnavailablePersonalityService()
    }
    return service
  }
}
