import HexCore
import Observation
import SwiftUI

struct HexAuthorizationModePickerView: View {
  @Bindable var model: HexResidentSetupModel
  @State private var isConfirmingFullAccess = false

  var body: some View {
    Section {
      VStack(spacing: 2) {
        ForEach(HexAuthorizationMode.allCases) { mode in
          HexApprovalModeRow(mode: mode, isSelected: model.authorizationMode == mode) {
            authorizationMode.wrappedValue = mode
          }
        }
      }
      .accessibilityIdentifier("authorizationModePicker")
      .disabled(model.isSaving || model.isLoading || model.needsLoadRetry)
    } header: {
      Text("Default action permissions")
    } footer: {
      Text(
        "Saving applies this default to conversations using the default and to scheduled work. Choose a different mode for an individual conversation in its composer. macOS privacy permissions remain separate."
      )
    }
    .confirmationDialog(
      "Use full access by default?",
      isPresented: $isConfirmingFullAccess,
      titleVisibility: .visible
    ) {
      Button("Use Full Access", role: .destructive) {
        model.authorizationMode = .fullAccess
      }
      Button("Keep Asking", role: .cancel) {}
    } message: {
      Text(
        "Hex will run validated requests, including commands with your Mac account's file access. macOS still controls Accessibility, Screen Recording, and other protected access."
      )
    }
  }

  private var authorizationMode: Binding<HexAuthorizationMode> {
    Binding(
      get: { model.authorizationMode },
      set: { mode in
        if mode == .fullAccess, model.authorizationMode != .fullAccess {
          isConfirmingFullAccess = true
        } else {
          model.authorizationMode = mode
        }
      }
    )
  }
}
