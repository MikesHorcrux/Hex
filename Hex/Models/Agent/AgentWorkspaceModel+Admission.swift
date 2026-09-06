import Foundation
import HexCore
import HexIPC

extension AgentWorkspaceModel {
  /// Construct and save the exact recoverable request before dispatch. A failed save leaves the
  /// conversation and draft untouched, and never crosses the gateway execution boundary.
  func prepareAdmission(
    prompt: String, userMessage: Message, runID: AgentRunID, selectedModelID: String
  ) {
    var candidate =
      conversations.first(where: { $0.id == selectedConversationID })
      ?? AgentConversation()
    let artifacts: [ArtifactReference]
    do { artifacts = try candidate.availableArtifacts() } catch {
      errorMessage =
        "Hex couldn't validate the saved output catalog. Your request was not sent and your draft is unchanged."
      return
    }
    do { try ToolArtifactValidation.validate(artifacts) } catch {
      errorMessage =
        "This conversation has more saved outputs than Hex can attach to one run yet. Your outputs are still saved and your draft is unchanged. Start a new conversation to continue."
      return
    }
    let request = GatewayStartRunRequest(
      runID: runID, modelID: ModelID(rawValue: selectedModelID),
      initialMessages: candidate.contextMessages() + [userMessage],
      options: InferenceOptions(reasoningEffort: selectedComposerEffort.inferenceValue),
      availableArtifacts: artifacts, authorizationMode: selectedComposerAuthorizationMode)
    var history = candidate.resolvedHistory()
    history.exchanges.append(AgentConversationExchange(runID: runID, messages: [userMessage]))
    candidate.history = history
    candidate.transcript = transcript + [ConversationItem(role: .user, text: prompt)]
    candidate.composerSelection = currentComposerSelection
    candidate.recordPrompt(prompt)
    candidate.pendingRun = AgentConversationRunCheckpoint(request: request)
    guard validateConversationAdmission(candidate) else { return }
    let archive = persistenceArchive(replacing: candidate)
    let originalDraft = draft
    let admittedConversation = candidate
    currentRunID = runID
    currentRunRequest = request
    currentInvocationID = nil
    currentRunGatewayInstanceID = nil
    currentAppliedSequence = 0
    currentFirstEventID = nil
    currentRunHasToolEvidence = false
    streamingAssistantItemID = nil
    cancellationRequested = false
    resetAuthorizations()
    pendingInitialMessageIDs = Set(request.initialMessages.map(\.id))
    isFailedRunRetryAvailable = false
    retryRequiresFreshRunID = false
    needsRunRecovery = false
    isPreparingAdmission = true
    runState = .starting
    errorMessage = nil
    activity = "Saving the request before starting…"

    runTask = Task { [weak self] in
      guard let self else { return }
      let saved = await saveArchiveNow(archive)
      guard currentRunID == runID else { return }
      isPreparingAdmission = false
      guard saved else {
        currentRunID = nil
        currentRunRequest = nil
        runState = .failed
        runTask = nil
        activity = "Request not sent. Your draft is unchanged."
        errorMessage =
          "Hex could not save this request, so it was not sent. Your draft is unchanged."
        return
      }
      if let index = conversations.firstIndex(where: { $0.id == admittedConversation.id }) {
        conversations[index] = admittedConversation
      } else {
        conversations.insert(admittedConversation, at: 0)
      }
      conversationPersistenceState.persistableConversations[admittedConversation.id] =
        admittedConversation
      selectedConversationID = admittedConversation.id
      transcript = admittedConversation.transcript
      if draft == originalDraft { draft = "" }
      if Task.isCancelled {
        runState = .cancelled
        currentRunRequest = nil
        updateHistoryOutcome(.cancelled)
        if draft.isEmpty { draft = originalDraft }
        runTask = nil
        activity = "Cancelled before dispatch. Your draft is preserved."
        return
      }
      await startRun(request)
    }
  }

  func resetAuthorizations() {
    pendingAuthorizations.removeAll()
    submittedAuthorizationIDs.removeAll()
    authorizationSubmissionID = nil
    authorizationSubmittingRequestID = nil
    isSubmittingAuthorization = false
  }
}
