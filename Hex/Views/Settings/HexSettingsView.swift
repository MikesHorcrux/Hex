import Observation
import SwiftUI

struct HexSettingsView: View {
  @Bindable var workspace: AgentWorkspaceModel
  @Bindable var residentSetup: HexResidentSetupModel
  @Bindable var inference: HexInferenceBackendSettingsModel
  @Bindable var heartbeat: HexHeartbeatManagementModel
  @Bindable var personality: HexPersonalitySettingsModel
  @Bindable var startAtLogin: HexStartAtLoginModel
  let route: HexGatewayRoute
  let suppressAutomaticRefresh: Bool

  @State private var selection = HexSettingsSection.general
  @AppStorage("hex.onboarding.completed.v1") private var hasCompletedOnboarding = false

  var body: some View {
    NavigationSplitView {
      List(HexSettingsSection.allCases, selection: $selection) { section in
        Label(section.title, systemImage: section.systemImage)
          .tag(section)
      }
      .listStyle(.sidebar)
      .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
    } detail: {
      detail
        .navigationTitle(selection.title)
    }
    .navigationSplitViewStyle(.balanced)
    .frame(minWidth: 760, minHeight: 560)
  }

  @ViewBuilder
  private var detail: some View {
    switch selection {
    case .general:
      HexGeneralSettingsView(
        workspace: workspace,
        startAtLogin: startAtLogin,
        route: route,
        suppressAutomaticRefresh: suppressAutomaticRefresh,
        onRunSetupAgain: {
          hasCompletedOnboarding = false
        }
      )
    case .inference:
      HexInferenceBackendSettingsView(model: inference)
    case .workspace:
      HexResidentSetupView(model: residentSetup)
    case .tools:
      HexToolsSettingsView(model: residentSetup)
    case .permissions:
      HexPermissionsSettingsView(model: residentSetup)
    case .personality:
      HexPersonalitySettingsView(model: personality)
    case .heartbeats:
      HexHeartbeatManagementView(
        model: heartbeat,
        suppressAutomaticRefresh: suppressAutomaticRefresh
      )
    }
  }
}
