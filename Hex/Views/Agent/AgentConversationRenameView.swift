import Observation
import SwiftUI

struct AgentConversationRenameView: View {
  @Bindable var model: AgentWorkspaceModel
  let conversation: AgentConversation
  @Environment(\.dismiss) private var dismiss
  @FocusState private var isNameFocused: Bool
  @State private var title: String
  @State private var isSaving = false
  @State private var errorMessage: String?

  init(model: AgentWorkspaceModel, conversation: AgentConversation) {
    self.model = model
    self.conversation = conversation
    _title = State(initialValue: conversation.title)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Rename conversation")
        .font(.title3.weight(.semibold))
        .foregroundStyle(HexBrandPalette.ink)
      Text("Give it a name that’s easy to find later.")
        .font(.callout)
        .foregroundStyle(HexBrandPalette.mutedInk)
      TextField("Conversation name", text: $title)
        .textFieldStyle(.roundedBorder)
        .focused($isNameFocused)
        .disabled(isSaving)
        .accessibilityIdentifier("conversationRenameField")
        .onSubmit(rename)

      if let errorMessage {
        Text(errorMessage)
          .font(.callout)
          .foregroundStyle(HexBrandPalette.warningInk)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("conversationRenameError")
      }

      HStack {
        Spacer()
        if isSaving { ProgressView().controlSize(.small) }
        Button("Cancel") { dismiss() }
          .buttonStyle(.hexSecondaryAction)
          .keyboardShortcut(.cancelAction)
          .disabled(isSaving)
        Button("Rename", action: rename)
          .buttonStyle(.hexPrimaryAction)
          .keyboardShortcut(.defaultAction)
          .disabled(isSaving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .accessibilityIdentifier("confirmConversationRename")
      }
    }
    .padding(24)
    .frame(width: 420)
    .background(HexBrandPalette.raisedSurface)
    .interactiveDismissDisabled(isSaving)
    .task { isNameFocused = true }
  }

  private func rename() {
    guard !isSaving, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    isSaving = true
    errorMessage = nil
    let requestedTitle = title
    Task {
      let saved = await model.renameConversation(conversation.id, to: requestedTitle)
      isSaving = false
      if saved {
        dismiss()
      } else {
        errorMessage = model.errorMessage ?? "The conversation could not be renamed. Try again."
      }
    }
  }
}
