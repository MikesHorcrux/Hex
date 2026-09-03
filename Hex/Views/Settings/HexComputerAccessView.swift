import Observation
import SwiftUI

struct HexComputerAccessView: View {
  @Bindable var accessibilityPermission: HexAccessibilityPermissionModel
  @Bindable var startAtLogin: HexStartAtLoginModel
  let suppressAutomaticRefresh: Bool

  @Environment(\.scenePhase) private var scenePhase

  init(
    accessibilityPermission: HexAccessibilityPermissionModel,
    startAtLogin: HexStartAtLoginModel,
    suppressAutomaticRefresh: Bool = false
  ) {
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

      HexExternalComputerPermissionsView()
    } header: {
      Text("Computer & Web")
    } footer: {
      Text(
        "Hex approvals and macOS privacy grants are separate. Requesting access never marks it granted; Hex verifies the resident agent again after you return."
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
    guard startAtLogin.status == .enabled else { return }
    await accessibilityPermission.refresh()
  }
}
