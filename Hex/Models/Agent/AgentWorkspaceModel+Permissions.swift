import HexCore
import HexIPC

extension AgentWorkspaceModel {
  var selectedComposerAuthorizationMode: HexAuthorizationMode {
    get {
      if isRunActive || needsRunRecovery, let admitted = currentRunRequest?.authorizationMode {
        return admitted
      }
      return rememberedComposerAuthorizationMode ?? defaultAuthorizationMode
    }
    set {
      setComposerAuthorizationOverride(newValue)
    }
  }

  var hasComposerAuthorizationOverride: Bool { rememberedComposerAuthorizationMode != nil }

  func useSavedComposerAuthorizationMode() {
    guard hasComposerAuthorizationOverride else { return }
    setComposerAuthorizationOverride(nil)
  }

  private func setComposerAuthorizationOverride(_ mode: HexAuthorizationMode?) {
    guard canChangeComposerAuthorizationMode, conversationArchiveWritesAreAllowed() else { return }
    var candidate =
      conversations.first(where: { $0.id == selectedConversationID }) ?? AgentConversation()
    candidate.transcript = transcript
    candidate.composerSelection = AgentComposerSelection(
      modelID: rememberedComposerModelID, effort: composerEffort, authorizationMode: mode)
    guard validateConversationAdmission(candidate) else { return }
    rememberedComposerAuthorizationMode = mode
    if let index = conversations.firstIndex(where: { $0.id == candidate.id }) {
      conversations[index] = candidate
    } else {
      conversations.insert(candidate, at: 0)
      selectedConversationID = candidate.id
    }
    persistConversationArchive()
  }

  var canChangeComposerAuthorizationMode: Bool {
    !isRunActive && !needsRunRecovery && !isRestoringConversations
      && !conversationPersistenceState.restoreFailed && conversationSaveError == nil
      && (!requiresConversationPersistence || conversationStore != nil)
      && (conversationStore == nil || didRestoreConversations)
      && selectedConversationID.flatMap({ conversationPersistenceState.unsavedReasons[$0] }) == nil
  }

  var currentComposerSelection: AgentComposerSelection {
    AgentComposerSelection(
      modelID: rememberedComposerModelID, effort: composerEffort,
      authorizationMode: rememberedComposerAuthorizationMode)
  }
}
