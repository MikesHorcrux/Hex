import Observation
import SwiftUI

struct HexPermissionsSettingsView: View {
  @Bindable var model: HexResidentSetupModel
  @Bindable var startAtLogin: HexStartAtLoginModel
  @Bindable var accessibilityPermission: HexAccessibilityPermissionModel
  let suppressAutomaticRefresh: Bool
  var approvals: HexApprovalInboxModel?
  @State private var isShowingApprovals = false

  var body: some View {
    Form {
      HexAuthorizationModePickerView(model: model)
      if approvals != nil {
        Section {
          Button("Approval inbox", systemImage: "hand.raised") { isShowingApprovals = true }
          Text("Review waiting actions and revoke session approvals, including scheduled work.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      HexComputerAccessView(
        model: model,
        accessibilityPermission: accessibilityPermission,
        startAtLogin: startAtLogin,
        suppressAutomaticRefresh: suppressAutomaticRefresh
      )

      if let statusMessage = model.statusMessage {
        HexInlineNoticeView(
          message: statusMessage,
          systemImage: "checkmark.circle.fill",
          tint: HexBrandPalette.successInk
        )
      }

      if let errorMessage = model.errorMessage {
        HexInlineNoticeView(
          message: errorMessage,
          systemImage: "exclamationmark.triangle.fill",
          tint: .orange
        )
      }

      HexResidentSetupLoadRetryView(model: model)

      HStack {
        Spacer()
        if model.isSaving {
          ProgressView()
            .controlSize(.small)
        }
        Button("Save") {
          model.save()
        }
        .buttonStyle(.hexPrimaryAction)
        .keyboardShortcut(.defaultAction)
        .disabled(!model.canSave)
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .tint(HexBrandPalette.coral)
    .task {
      await model.load()
    }
    .sheet(isPresented: $isShowingApprovals) {
      if let approvals { HexApprovalInboxView(model: approvals) }
    }
  }
}
