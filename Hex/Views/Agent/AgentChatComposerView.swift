import HexCore
import SwiftUI

struct AgentChatComposerView: View {
  @Bindable var model: AgentChatWorkspaceModel
  @Bindable var workspace: AgentWorkspaceModel
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      TextField(
        model.activeWork?.phase == .blocked ? "What did you verify?" : "Message Hex…",
        text: $model.draft, axis: .vertical
      )
      .lineLimit(2...6).textFieldStyle(.plain).accessibilityIdentifier("conversationComposer")
      .disabled(model.pending != nil || model.selected?.archivedAt != nil)
      Divider()
      HStack {
        AgentApprovalModeMenu(
          selection: $workspace.selectedComposerAuthorizationMode,
          isEnabled: workspace.canChangeComposerAuthorizationMode && model.activeWork == nil
            && model.pending == nil && !model.isSubmitting && model.storageReady,
          savedDefaultMode: workspace.defaultAuthorizationMode,
          hasOverride: workspace.hasComposerAuthorizationOverride,
          onUseSavedDefault: workspace.useSavedComposerAuthorizationMode)
        AgentComposerOptionsView(
          models: workspace.availableComposerModels,
          efforts: workspace.availableComposerEfforts,
          selectedModelID: $workspace.selectedComposerModelID,
          selectedEffort: $workspace.selectedComposerEffort,
          isEnabled: !model.isSubmitting && model.activeWork == nil && model.pending == nil
            && model.storageReady,
          isLoading: workspace.isLoadingModels,
          onRefresh: { Task { await workspace.refreshAvailableModels() } })
        Spacer()
        if model.activeWork != nil && model.activeWork?.phase != .blocked && model.pending == nil {
          Button("Send next") { Task { await model.send(workspace: workspace, enqueue: true) } }
            .help("Save this message for after the current work finishes")
            .disabled(cannotSend)
        }
        Button(
          model.pending != nil
            ? "Retry send" : model.activeWork?.phase == .blocked ? "Confirm and continue" : "Send"
        ) {
          Task { await model.send(workspace: workspace) }
        }.buttonStyle(.hexPrimaryAction).keyboardShortcut(.return, modifiers: .command)
          .disabled(cannotSend)
      }
      if model.activeWork != nil && model.activeWork?.phase != .blocked {
        Text("Send updates the current work. Send next queues a follow-up.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }.padding(15).hexSurface(cornerRadius: 20, fill: HexBrandPalette.raisedSurface, shadowRadius: 8)
  }
  private var cannotSend: Bool {
    model.isSubmitting || !model.storageReady || workspace.connectionState != .connected
      || !workspace.isComposerSelectionAvailable
      || model.selected?.archivedAt != nil
      || (model.pending == nil
        && model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }
}
