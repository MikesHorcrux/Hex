import HexCore
import SwiftUI

struct AgentChatComposerView: View {
  @Bindable var model: AgentChatWorkspaceModel
  @Bindable var workspace: AgentWorkspaceModel
  @FocusState private var isFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      TextField(placeholder, text: $model.draft, axis: .vertical)
        .lineLimit(2...6).textFieldStyle(.plain)
        .font(.body).focused($isFocused)
        .accessibilityIdentifier("conversationComposer")
        .disabled(model.pending != nil || model.selected?.archivedAt != nil)
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) {
          options
          Spacer(minLength: 8)
          actions
        }
        VStack(alignment: .leading, spacing: 8) {
          options
          HStack {
            Spacer()
            actions
          }
        }
      }
      if model.activeWork != nil && model.activeWork?.phase != .blocked {
        Text("Send updates this work. Send next queues a follow-up.")
          .font(.caption).foregroundStyle(HexBrandPalette.mutedInk)
      }
    }
    .padding(16)
    .hexSurface(
      cornerRadius: 18, fill: HexBrandPalette.raisedSurface,
      border: isFocused ? HexBrandPalette.accentInk.opacity(0.8) : HexBrandPalette.hairline,
      shadowRadius: 0
    )
    .onChange(of: model.selectedID) { _, _ in isFocused = true }
  }

  private var options: some View {
    HStack(spacing: 10) {
      AgentComposerOptionsView(
        models: workspace.availableComposerModels, efforts: workspace.availableComposerEfforts,
        selectedModelID: $workspace.selectedComposerModelID,
        selectedEffort: $workspace.selectedComposerEffort,
        isEnabled: !model.isSubmitting && model.activeWork == nil && model.pending == nil
          && model.storageReady,
        isLoading: workspace.isLoadingModels,
        onRefresh: { Task { await workspace.refreshAvailableModels() } }, isCompact: true)
      Divider().frame(height: 14)
      AgentApprovalModeMenu(
        selection: $workspace.selectedComposerAuthorizationMode,
        isEnabled: workspace.canChangeComposerAuthorizationMode && model.activeWork == nil
          && model.pending == nil && !model.isSubmitting && model.storageReady,
        savedDefaultMode: workspace.defaultAuthorizationMode,
        hasOverride: workspace.hasComposerAuthorizationOverride,
        onUseSavedDefault: workspace.useSavedComposerAuthorizationMode, isCompact: true)
    }
  }

  private var actions: some View {
    HStack(spacing: 10) {
      if model.activeWork != nil && model.activeWork?.phase != .blocked && model.pending == nil {
        Button("Send next") { Task { await model.send(workspace: workspace, enqueue: true) } }
          .buttonStyle(.plain).font(.caption)
          .help("Save this message for after the current work finishes")
          .disabled(cannotSend)
      }
      Button {
        Task { await model.send(workspace: workspace) }
      } label: {
        if model.pending != nil || model.activeWork?.phase == .blocked {
          Text(model.pending != nil ? "Retry send" : "Confirm and continue")
        } else {
          Image(systemName: "arrow.up").font(.system(size: 16, weight: .semibold))
            .frame(width: 8, height: 20)
        }
      }
      .buttonStyle(.hexPrimaryAction)
      .keyboardShortcut(.return, modifiers: .command)
      .accessibilityLabel(
        model.pending != nil
          ? "Retry send" : model.activeWork?.phase == .blocked ? "Confirm and continue" : "Send"
      )
      .accessibilityIdentifier("conversationSend")
      .help("Send message (⌘Return)")
      .disabled(cannotSend)
    }
  }

  private var placeholder: String {
    if model.selected?.archivedAt != nil { return "Unarchive this conversation to reply" }
    return model.activeWork?.phase == .blocked ? "What did you verify?" : "Message Hex…"
  }

  private var cannotSend: Bool {
    model.isSubmitting || !model.storageReady || workspace.connectionState != .connected
      || !workspace.isComposerSelectionAvailable || model.selected?.archivedAt != nil
      || (model.pending == nil
        && model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }
}
