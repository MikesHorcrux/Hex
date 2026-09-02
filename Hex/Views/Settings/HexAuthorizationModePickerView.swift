import HexCore
import Observation
import SwiftUI

struct HexAuthorizationModePickerView: View {
  @Bindable var model: HexResidentSetupModel
  @State private var isConfirmingFullAccess = false

  var body: some View {
    Section {
      Picker("Approval policy", selection: authorizationMode) {
        Text("Ask for each new capability scope")
          .tag(HexAuthorizationMode.askEveryTime)
        Text("Full Access")
          .tag(HexAuthorizationMode.fullAccess)
      }
      .pickerStyle(.radioGroup)
      .accessibilityIdentifier("authorizationModePicker")

      if model.authorizationMode == .fullAccess {
        Label(
          "Validated tool requests run without a Hex approval prompt.",
          systemImage: "exclamationmark.shield.fill"
        )
        .foregroundStyle(.orange)
      }
    } header: {
      Text("Hex approvals")
    } footer: {
      Text(
        "Full Access does not escape the selected workspace, tool validation, network policy, "
          + "or macOS privacy controls. Restart the resident gateway after changing this policy."
      )
    }
    .confirmationDialog(
      "Give Hex Full Access?",
      isPresented: $isConfirmingFullAccess,
      titleVisibility: .visible
    ) {
      Button("Enable Full Access", role: .destructive) {
        model.authorizationMode = .fullAccess
      }
      Button("Keep Asking", role: .cancel) {}
    } message: {
      Text(
        "Hex will automatically approve valid tool requests inside its configured boundaries. "
          + "macOS will still control Accessibility, Screen Recording, and other system access."
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
