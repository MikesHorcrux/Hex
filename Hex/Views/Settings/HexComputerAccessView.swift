import Observation
import SwiftUI

struct HexComputerAccessView: View {
  @Bindable var model: HexResidentSetupModel
  @Bindable var accessibilityPermission: HexAccessibilityPermissionModel
  @Bindable var startAtLogin: HexStartAtLoginModel
  let suppressAutomaticRefresh: Bool

  @Environment(\.scenePhase) private var scenePhase

  init(
    model: HexResidentSetupModel,
    accessibilityPermission: HexAccessibilityPermissionModel,
    startAtLogin: HexStartAtLoginModel,
    suppressAutomaticRefresh: Bool = false
  ) {
    self.model = model
    self.accessibilityPermission = accessibilityPermission
    self.startAtLogin = startAtLogin
    self.suppressAutomaticRefresh = suppressAutomaticRefresh
  }

  var body: some View {
    Section {
      HexResidentAgentAccessView(
        accessibilityPermission: accessibilityPermission,
        startAtLogin: startAtLogin
      )

      Divider()

      HexExternalComputerPermissionsView(model: model)
    } header: {
      Text("Mac permissions")
    } footer: {
      Text(
        "Hex only marks access ready after the always-on agent verifies it. macOS remains the final authority for protected access."
      )
    }
    .task {
      guard !suppressAutomaticRefresh else { return }
      await refreshGatewayAndPermission()
    }
    .onChange(of: startAtLogin.status) { _, status in
      guard !suppressAutomaticRefresh, status == .enabled else { return }
      Task {
        await accessibilityPermission.refresh()
      }
    }
    .onChange(of: scenePhase) { _, phase in
      guard !suppressAutomaticRefresh, phase == .active else { return }
      Task {
        await refreshGatewayAndPermission()
      }
    }
  }

  private func refreshGatewayAndPermission() async {
    await startAtLogin.refresh()
    await model.refreshScreenControlPermissions()
    guard startAtLogin.status == .enabled else { return }
    await accessibilityPermission.refresh()
  }
}
