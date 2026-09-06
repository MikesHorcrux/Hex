import Observation
import SwiftUI

struct HexSettingsView: View {
  @Bindable var workspace: AgentWorkspaceModel
  @Bindable var residentSetup: HexResidentSetupModel
  @Bindable var toolConnections: HexToolConnectionsModel
  @Bindable var inference: HexInferenceBackendSettingsModel
  @Bindable var heartbeat: HexHeartbeatManagementModel
  @Bindable var personality: HexPersonalitySettingsModel
  @Bindable var startAtLogin: HexStartAtLoginModel
  @Bindable var accessibilityPermission: HexAccessibilityPermissionModel
  let route: HexGatewayRoute
  let suppressAutomaticRefresh: Bool

  @State private var selection = HexSettingsSection.general
  @AppStorage("hex.onboarding.completed.v1") private var hasCompletedOnboarding = false

  var body: some View {
    NavigationSplitView {
      VStack(spacing: 0) {
        HStack(spacing: 11) {
          HexBrandMarkView(size: 48)
          VStack(alignment: .leading, spacing: 2) {
            Text("Hex")
              .font(.title3.weight(.bold))
              .foregroundStyle(HexBrandPalette.ink)
            Text("Personal Mac agent")
              .font(.caption)
              .foregroundStyle(HexBrandPalette.mutedInk)
          }
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)

        Rectangle()
          .fill(HexBrandPalette.hairline)
          .frame(height: 1)

        List(HexSettingsSection.allCases, selection: $selection) { section in
          Label(title(for: section), systemImage: section.systemImage)
            .tag(section)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
      }
      .background(HexBrandPalette.sidebarTint)
      .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
    } detail: {
      VStack(spacing: 0) {
        HexSettingsPageHeaderView(
          title: title(for: selection),
          detail: description(for: selection),
          systemImage: selection.systemImage
        )
        detail
          .scrollContentBackground(.hidden)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .background(HexBrandPalette.canvas)
      .navigationTitle(title(for: selection))
    }
    .navigationSplitViewStyle(.balanced)
    .tint(HexBrandPalette.coral)
    .frame(minWidth: 840, minHeight: 620)
  }

  private func title(for section: HexSettingsSection) -> String {
    switch section {
    case .general:
      "General"
    case .inference:
      "AI model"
    case .workspace:
      "Workspace"
    case .tools:
      "Tools"
    case .permissions:
      "Mac access"
    case .personality:
      "Personality & memory"
    case .heartbeats:
      "Automations"
    }
  }

  private func description(for section: HexSettingsSection) -> String {
    switch section {
    case .general:
      "Control how Hex stays available and revisit setup when you need to."
    case .inference:
      "Choose where Hex gets its answers. Hex still owns the tools, memory, and agent loop."
    case .workspace:
      "Set the local folder where Hex may read, edit, search, and run commands."
    case .tools:
      "Choose the browser, screen, developer, and connected tools Hex may use."
    case .permissions:
      "See what Hex can access, what macOS still needs, and what action comes next."
    case .personality:
      "Shape Hex's voice and manage the memories you explicitly want it to keep."
    case .heartbeats:
      "Manage the scheduled work Hex performs while its always-on agent is available."
    }
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
      HexToolsSettingsView(
        model: residentSetup, connections: toolConnections, workspace: workspace,
        suppressAutomaticRefresh: suppressAutomaticRefresh)
    case .permissions:
      HexPermissionsSettingsView(
        model: residentSetup,
        startAtLogin: startAtLogin,
        accessibilityPermission: accessibilityPermission,
        suppressAutomaticRefresh: suppressAutomaticRefresh
      )
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
