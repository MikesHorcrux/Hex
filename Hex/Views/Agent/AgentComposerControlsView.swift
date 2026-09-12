import HexCore
import SwiftUI

struct AgentComposerControlsView: View {
  let availableModels: [AgentComposerModelOption]
  let availableEfforts: [AgentComposerEffort]
  let isLoadingModels: Bool
  @Binding var selectedModelID: String?
  @Binding var selectedEffort: AgentComposerEffort
  @Binding var selectedAuthorizationMode: HexAuthorizationMode
  let canChangeAuthorizationMode: Bool
  let savedAuthorizationMode: HexAuthorizationMode
  let hasAuthorizationOverride: Bool
  let onUseSavedAuthorizationMode: () -> Void
  let canChangeOptions: Bool
  let canSend: Bool
  let isRunning: Bool
  let onSend: () -> Void
  let onCancel: () -> Void
  let onRefreshModels: () -> Void

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) {
        permissions
        Spacer(minLength: 4)
        options
        actions
      }
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          permissions
          Spacer()
          actions
        }
        options
      }
    }
  }

  private var permissions: some View {
    AgentApprovalModeMenu(
      selection: $selectedAuthorizationMode, isEnabled: canChangeAuthorizationMode,
      savedDefaultMode: savedAuthorizationMode, hasOverride: hasAuthorizationOverride,
      onUseSavedDefault: onUseSavedAuthorizationMode)
  }

  private var options: some View {
    AgentComposerOptionsView(
      models: availableModels, efforts: availableEfforts,
      selectedModelID: $selectedModelID, selectedEffort: $selectedEffort,
      isEnabled: canChangeOptions, isLoading: isLoadingModels,
      onRefresh: onRefreshModels)
  }

  private var actions: some View {
    HStack(spacing: 10) {
      if isRunning {
        Button("Cancel", action: onCancel)
          .buttonStyle(.hexSecondaryAction)
          .keyboardShortcut(".", modifiers: [.command])
          .accessibilityIdentifier("cancelRunButton")
      }
      Button(action: onSend) {
        Label("Send", systemImage: "arrow.up")
      }
      .buttonStyle(.hexPrimaryAction)
      .keyboardShortcut(.return, modifiers: [.command])
      .disabled(!canSend)
      .accessibilityHint("Sends the current message to Hex")
      .accessibilityIdentifier("sendPromptButton")
    }
    .fixedSize()
  }
}
