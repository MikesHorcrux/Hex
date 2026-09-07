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
      if model.screenControlPermissionError != nil,
        !accessibilityPermission.state.canRepairByRestartingGateway,
        startAtLogin.status == .enabled
      {
        Button("Restart Hex Agent") {
          Task {
            await startAtLogin.restart()
            guard startAtLogin.message == nil else { return }
            await refreshGatewayAndPermission()
          }
        }
        .disabled(!startAtLogin.canRestart || model.isRequestingScreenControl)
        Text("Restarting interrupts active work. No Mac privacy permission will be changed.")
          .font(.caption).foregroundStyle(.secondary)
      }
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
      guard !suppressAutomaticRefresh else { return }
      guard status == .enabled else {
        model.invalidateVerifiedPermissions()
        accessibilityPermission.invalidate()
        return
      }
      Task {
        await refreshGatewayAndPermission()
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
    guard startAtLogin.status == .enabled else {
      model.invalidateVerifiedPermissions()
      accessibilityPermission.invalidate()
      return
    }
    async let accessibility: Void = accessibilityPermission.refresh()
    async let screen: Void = model.refreshScreenControlPermissions()
    async let folder: Void = model.folderAccess.refresh(ifPreviouslyRequested: true)
    _ = await (accessibility, screen, folder)
  }
}
