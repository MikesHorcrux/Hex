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
  @State private var heartbeatManagement: HexHeartbeatManagementModel
  @State private var personalitySettings: HexPersonalitySettingsModel
  @State private var inferenceBackendSettings: HexInferenceBackendSettingsModel
  private let route: HexGatewayRoute
  private let isVerificationOnlyLaunch: Bool

  init() {
    let configuration = HexDeveloperConfiguration(
      environment: ProcessInfo.processInfo.environment
    )
    let client = HexLiveAgentClient(configuration: configuration)
    let initialModelID =
      configuration.gatewayRoute.isResident
      ? ""
      : configuration.modelIDForInterface
    let verificationOnlyLaunch = Self.isVerificationOnlyLaunch(arguments: CommandLine.arguments)
    #if DEBUG
      let setupDependencies = HexResidentSetupDependencies.live(for: configuration.gatewayRoute)
    #else
      let setupDependencies = HexResidentSetupDependencies.blocked
    #endif
    let inferenceBackendDependencies =
      HexInferenceBackendSettingsDependencies.live(for: configuration.gatewayRoute)
    self.init(
      client: client,
      modelID: initialModelID,
      route: configuration.gatewayRoute,
      residentGatewayController: client,
      setupDependencies: setupDependencies,
      heartbeatService: nil,
      personalityService: nil,
      personalityMemoryScope: .hex,
      inferenceBackendDependencies: inferenceBackendDependencies,
      isVerificationOnlyLaunch: verificationOnlyLaunch
    )
  }

  init(
    client: any HexAgentClient = PreviewHexAgentClient(),
    modelID: String = "preview",
    route: HexGatewayRoute = .residentXPC(),
    residentGatewayController: any HexResidentGatewayControlling =
      HexUnavailableResidentGatewayController(),
    setupDependencies: HexResidentSetupDependencies = .blocked,
    heartbeatService: (any HexHeartbeatManaging)? = nil,
    personalityService: (any HexPersonalityServicing)? = nil,
    personalityMemoryScope: PersonalMemoryScope = .hex,
    inferenceBackendDependencies: HexInferenceBackendSettingsDependencies = .blocked,
    lifecycleController: any HexGatewayLifecycleControlling =
      HexSMAppServiceLifecycleController(),
    isVerificationOnlyLaunch: Bool = false
  ) {
    self.route = route
    self.isVerificationOnlyLaunch = isVerificationOnlyLaunch
    _workspace = State(initialValue: AgentWorkspaceModel(client: client, modelID: modelID))
    _residentGateway = State(
      initialValue: HexResidentGatewayModel(controller: residentGatewayController)
    )
    _startAtLogin = State(
      initialValue: HexStartAtLoginModel(
        controller: lifecycleController,
        readinessChecker: setupDependencies.readinessChecker
      )
    )
    _residentSetup = State(
      initialValue: HexResidentSetupModel(
        initialModelID: modelID,
        settingsStore: setupDependencies.settingsStore,
        secretStore: setupDependencies.secretStore,
        managedToolLayout: setupDependencies.managedToolLayout
      )
    )

    let resolvedHeartbeatService: any HexHeartbeatManaging
    if let heartbeatService {
      resolvedHeartbeatService = heartbeatService
    } else if route.isResident, let heartbeatClient = client as? any HexHeartbeatManaging {
      resolvedHeartbeatService = heartbeatClient
    } else {
      resolvedHeartbeatService = HexUnavailableHeartbeatService()
    }
    _heartbeatManagement = State(
      initialValue: HexHeartbeatManagementModel(service: resolvedHeartbeatService)
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
        makeCodexStatusProvider: inferenceBackendDependencies.makeCodexStatusProvider
      )
    )
  }

  var body: some Scene {
    WindowGroup(id: "main") {
      AgentWorkspaceView(model: workspace, connectOnAppear: false)
        .task {
          guard !isVerificationOnlyLaunch else { return }
          await residentSetup.load()
          workspace.modelID = residentSetup.modelID
          await workspace.connect()
        }
        .onChange(of: residentSetup.saveGeneration) { _, _ in
          guard !isVerificationOnlyLaunch else { return }
          workspace.modelID = residentSetup.modelID
          Task {
            await startAtLogin.refresh()
          }
        }
    }

    Settings {
      TabView {
        HexResidentSetupView(model: residentSetup)
          .tabItem {
            Label("Resident", systemImage: "server.rack")
          }

        HexInferenceBackendSettingsView(model: inferenceBackendSettings)
          .tabItem {
            Label("Inference", systemImage: "cpu")
          }

        HexHeartbeatManagementView(
          model: heartbeatManagement,
          suppressAutomaticRefresh: isVerificationOnlyLaunch
        )
        .tabItem {
          Label("Heartbeats", systemImage: "calendar.badge.clock")
        }

        HexPersonalitySettingsView(model: personalitySettings)
          .tabItem {
            Label("Personality", systemImage: "person.crop.circle")
          }
      }
      .frame(minWidth: 560, minHeight: 500)
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
