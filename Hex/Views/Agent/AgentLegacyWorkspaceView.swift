import HexCore
import Observation
import SwiftUI

struct AgentLegacyWorkspaceView: View {
  @Bindable var model: AgentWorkspaceModel
  let connectOnAppear: Bool
  @FocusState private var isComposerFocused: Bool
  @State private var selectedArtifact: ArtifactReference?

  init(model: AgentWorkspaceModel, connectOnAppear: Bool = true) {
    _model = Bindable(model)
    self.connectOnAppear = connectOnAppear
  }

  var body: some View {
    NavigationSplitView {
      AgentSidebarView(model: model)
        .navigationSplitViewColumnWidth(min: 240, ideal: 264, max: 310)
    } detail: {
      Group {
        ZStack {
          LinearGradient(
            colors: [
              HexBrandPalette.canvas,
              HexBrandPalette.softCoral.opacity(0.24),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
          .ignoresSafeArea()

          VStack(spacing: 0) {
            AgentWorkspaceStatusView(model: model)

            if let error = model.errorMessage {
              ErrorBannerView(
                message: error,
                onRetry: model.canRetryLastFailure ? { model.retryLastFailure() } : nil,
                onDismiss: model.dismissError
              )
            }

            if let saveError = model.conversationSaveError {
              ErrorBannerView(
                message: saveError,
                onRetry: { model.persistConversationArchive() },
                onDismiss: nil,
                retryTitle: "Try saving again"
              )
              .accessibilityIdentifier("conversationSaveFailureBanner")
            }

            AgentConversationView(
              items: model.presentedTranscript,
              onPromptSuggestion: { prompt in
                model.draft = prompt
                isComposerFocused = true
              },
              onOpenArtifact: { selectedArtifact = $0 },
              hasEarlierMessages: model.hasEarlierTranscript,
              showsLatestButton: model.isViewingEarlierTranscript,
              isLoadingHistory: model.isRunActive,
              onEarlierMessages: { Task { await model.loadEarlierTranscript() } },
              onLatestMessages: { Task { await model.loadLatestTranscript() } }
            )

            if let request = model.pendingAuthorization {
              AgentToolAuthorizationView(
                request: request,
                isSubmitting: model.isSubmittingAuthorization,
                onChoice: model.decideAuthorization
              )
              .frame(maxWidth: 860)
              .padding(.horizontal, 24)
              .padding(.bottom, 12)
            }

            AgentComposerView(
              draft: $model.draft,
              availableModels: model.availableComposerModels,
              availableEfforts: model.availableComposerEfforts,
              isLoadingModels: model.isLoadingModels,
              selectionNotice: model.isComposerSelectionAvailable
                ? model.modelCatalogNotice
                : "Choose an available model and effort to continue this conversation.",
              selectedModelID: $model.selectedComposerModelID,
              selectedEffort: $model.selectedComposerEffort,
              selectedAuthorizationMode: $model.selectedComposerAuthorizationMode,
              canChangeAuthorizationMode: model.canChangeComposerAuthorizationMode,
              savedAuthorizationMode: model.defaultAuthorizationMode,
              hasAuthorizationOverride: model.hasComposerAuthorizationOverride,
              onUseSavedAuthorizationMode: model.useSavedComposerAuthorizationMode,
              focus: $isComposerFocused,
              canSend: model.canSend,
              canChangeOptions: model.canChangeComposerOptions,
              isRunning: model.canCancelRun,
              onSend: model.send,
              onCancel: model.cancel,
              onRefreshModels: { Task { await model.refreshAvailableModels() } }
            )
          }
        }
      }
      .navigationTitle("Hex")
      .inspector(
        isPresented: Binding(
          get: { selectedArtifact != nil },
          set: { if !$0 { selectedArtifact = nil } }
        )
      ) {
        if let selectedArtifact {
          AgentArtifactPreviewView(reference: selectedArtifact, client: model.client)
            .id(selectedArtifact.id)
            .inspectorColumnWidth(min: 320, ideal: 440, max: 660)
        }
      }
      .toolbar {
        ToolbarItemGroup {
          Button(
            "New conversation", systemImage: "square.and.pencil", action: model.newConversation)

          if model.connectionState != .disconnected || model.isRunActive && model.canDisconnect {
            Button(action: model.disconnectFromControl) {
              Label("Disconnect", systemImage: "bolt.slash")
            }
            .disabled(!model.canDisconnect)
          } else {
            Button(action: model.connectFromControl) {
              Label("Connect", systemImage: "bolt")
            }
            .disabled(model.connectionState == .connecting)
          }

          SettingsLink {
            Label("Settings", systemImage: "gearshape")
          }
        }
      }
    }
    .navigationSplitViewStyle(.balanced)
    .tint(HexBrandPalette.coral)
    .frame(minWidth: 900, minHeight: 650)
    .task {
      await model.restoreConversationHistory()
      guard connectOnAppear else { return }
      await model.connectAutomatically()
    }
  }
}
