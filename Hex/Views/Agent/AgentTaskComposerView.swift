import HexCore
import HexIPC
import SwiftUI

struct AgentTaskComposerView: View {
  @Bindable var model: AgentTaskWorkspaceModel
  @Bindable var workspace: AgentWorkspaceModel
  let onSubmit: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("New task").font(.caption.bold()).foregroundStyle(HexBrandPalette.ink)
      TextField("What should Hex get done?", text: $model.draft, axis: .vertical)
        .lineLimit(3...6).textFieldStyle(.plain).accessibilityIdentifier("durableTaskComposer")
        .disabled(model.submission != nil)
      Divider()
      ViewThatFits(in: .horizontal) {
        HStack {
          permissions
          Spacer()
          options
          submit
        }
        VStack(alignment: .leading) {
          HStack {
            permissions
            Spacer()
            submit
          }
          options
        }
      }
    }.padding(15)
      .hexSurface(cornerRadius: 20, fill: HexBrandPalette.raisedSurface, shadowRadius: 8)
  }

  private var permissions: some View {
    AgentApprovalModeMenu(
      selection: $workspace.selectedComposerAuthorizationMode,
      isEnabled: workspace.canChangeComposerAuthorizationMode,
      savedDefaultMode: workspace.defaultAuthorizationMode,
      hasOverride: workspace.hasComposerAuthorizationOverride,
      onUseSavedDefault: workspace.useSavedComposerAuthorizationMode)
  }
  private var options: some View {
    AgentComposerOptionsView(
      models: workspace.availableComposerModels, efforts: workspace.availableComposerEfforts,
      selectedModelID: $workspace.selectedComposerModelID,
      selectedEffort: $workspace.selectedComposerEffort,
      isEnabled: workspace.canChangeComposerOptions, isLoading: workspace.isLoadingModels,
      onRefresh: { Task { await workspace.refreshAvailableModels() } })
  }
  private var submit: some View {
    Button(model.submission == nil ? "Queue task" : "Retry admission", action: onSubmit)
      .buttonStyle(.hexPrimaryAction)
      .disabled(
        model.isSubmitting || !workspace.isComposerSelectionAvailable
          || (model.submission == nil
            && model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      )
      .keyboardShortcut(.return, modifiers: .command)
  }
}
