import Foundation
import HexCore
import HexIPC
import Observation

@MainActor
@Observable
final class AgentWorkspaceModel {
  @ObservationIgnored var transcript: [ConversationItem] = [] {
    didSet { scheduleTranscriptPresentation() }
  }
  var presentedTranscript: [ConversationItem] = []
  @ObservationIgnored var transcriptPresentationTask: Task<Void, Never>?
  var conversations: [AgentConversation] = [] {
    didSet { conversationSearchRevision &+= 1 }
  }
  private(set) var conversationSearchRevision: UInt64 = 0
  var selectedConversationID: UUID?
  var isRestoringConversations = false
  var chatWorkspace: AgentChatWorkspaceModel?
  var draft = ""
  var modelID: String {
    didSet {
      if oldValue != modelID { discoveredModels = [] }
    }
  }
  var rememberedComposerModelID: String?
  var composerEffort: AgentComposerEffort
  var defaultAuthorizationMode: HexAuthorizationMode
  var rememberedComposerAuthorizationMode: HexAuthorizationMode?
  var discoveredModels: [ModelDescriptor] = []
  private(set) var isLoadingModels = false
  private(set) var modelCatalogNotice: String?
  private(set) var connectionState: AgentConnectionState = .disconnected
  var runState: AgentRunState = .idle
  var pendingAuthorizations: [AuthorizationRequest] = []
  var pendingAuthorization: AuthorizationRequest? {
    guard !isRecoveringRun, !cancellationRequested, connectionState == .connected, isRunActive
    else { return nil }
    return pendingAuthorizations.first { !submittedAuthorizationIDs.contains($0.id) }
  }
  var isSubmittingAuthorization = false
  var errorMessage: String?
  var activity = "Connect to a gateway to begin."
  private(set) var gatewaySummary = "No gateway session"
  var currentRunID: AgentRunID?

  let client: any HexAgentClient
  @ObservationIgnored let conversationStore: (any AgentConversationStoring)?
  @ObservationIgnored let requiresConversationPersistence: Bool
  @ObservationIgnored let composerPreferenceStore: (any AgentComposerPreferenceStoring)?
  // The observer slot also gates navigation after a terminal receipt, until its final ACK drains.
  // Observe its release so controls unlock even when the visible run state is already terminal.
  var runTask: Task<Void, Never>?
  @ObservationIgnored var conversationPersistenceTask: Task<Void, Never>?
  @ObservationIgnored var checkpointTimer: Task<Void, Never>?
  @ObservationIgnored var archiveWriteQueue:
    [(revision: UInt64, archive: AgentConversationArchive, barrier: Bool)] = []
  @ObservationIgnored var archiveWriteWaiters: [UInt64: CheckedContinuation<Bool, Never>] = [:]
  @ObservationIgnored var archiveRevision: UInt64 = 0
  @ObservationIgnored var savedArchiveRevision: UInt64 = 0
  @ObservationIgnored var savedConversationSnapshots: [UUID: AgentConversation] = [:]
  var isLoadingConversation = false
  var olderTranscriptCursor: Int64?
  var hasEarlierTranscript = false
  var isViewingEarlierTranscript = false
  var conversationListRevision: UInt64 = 0
  var conversationSaveError: String?
  @ObservationIgnored var isReducingRunEvent = false
  @ObservationIgnored var isPreparingAdmission = false
  var isRecoveringRun = false
  @ObservationIgnored var needsRunRecovery = false
  @ObservationIgnored var connectedGatewayInstanceID: GatewayInstanceID?
  @ObservationIgnored var currentRunGatewayInstanceID: GatewayInstanceID?
  @ObservationIgnored var currentAppliedSequence: UInt64 = 0
  @ObservationIgnored var currentFirstEventID: AgentEventID?
  @ObservationIgnored var cancellationRequested = false
  var submittedAuthorizationIDs: Set<AuthorizationRequestID> = []
  @ObservationIgnored var authorizationSubmissionID: UUID?
  @ObservationIgnored var authorizationSubmittingRequestID: AuthorizationRequestID?
  @ObservationIgnored var currentInvocationID: GatewayRunInvocationID?
  @ObservationIgnored var currentRunRequest: GatewayStartRunRequest?
  @ObservationIgnored var isFailedRunRetryAvailable = false
  @ObservationIgnored var retryRequiresFreshRunID = false
  @ObservationIgnored var currentRunHasToolEvidence = false
  @ObservationIgnored var streamingAssistantItemID: UUID?
  @ObservationIgnored var pendingInitialMessageIDs: Set<MessageID> = []
  @ObservationIgnored var didRestoreConversations = false
  @ObservationIgnored var automaticConnectionSuppressedByUser = false
  @ObservationIgnored var residentActivationReconnectPending = false
  @ObservationIgnored var automaticDeliveryRecoveryRunID: AgentRunID?
  @ObservationIgnored var conversationPersistenceState = AgentConversationPersistenceState()

  init(
    client: any HexAgentClient,
    modelID: String = "preview",
    conversationStore: (any AgentConversationStoring)? = nil,
    requiresConversationPersistence: Bool = false,
    composerPreferenceStore: (any AgentComposerPreferenceStoring)? = nil,
    defaultAuthorizationMode: HexAuthorizationMode = .askEveryTime
  ) {
    self.client = client
    if let taskClient = client as? any HexGatewayTaskClient,
      let storage = client as? any ConversationStorage
    {
      chatWorkspace = AgentChatWorkspaceModel(
        client: client, taskClient: taskClient, storage: storage)
    }
    self.modelID = modelID
    self.conversationStore = conversationStore
    self.requiresConversationPersistence = requiresConversationPersistence
    self.composerPreferenceStore = composerPreferenceStore
    self.defaultAuthorizationMode = defaultAuthorizationMode
    rememberedComposerModelID = composerPreferenceStore?.selectedModelID()
    composerEffort = composerPreferenceStore?.selectedEffort() ?? .automatic
  }

  var availableComposerModels: [AgentComposerModelOption] {
    if !discoveredModels.isEmpty { return discoveredModels.map(AgentComposerModelOption.init) }
    let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedModelID.isEmpty else { return [] }
    return [AgentComposerModelOption(modelID: normalizedModelID)]
  }

  var selectedComposerModelID: String? {
    get { rememberedComposerModelID }
    set {
      guard canChangeComposerOptions else { return }
      let normalizedModelID = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
      guard
        normalizedModelID == nil
          || availableComposerModels.contains(where: { $0.id.rawValue == normalizedModelID })
      else {
        return
      }
      rememberedComposerModelID = normalizedModelID
      composerPreferenceStore?.saveSelectedModelID(normalizedModelID)
      if !availableComposerEfforts.contains(composerEffort) {
        composerEffort = .automatic
        composerPreferenceStore?.saveSelectedEffort(.automatic)
      }
      persistConversationArchive()
    }
  }

  var selectedComposerEffort: AgentComposerEffort {
    get { composerEffort }
    set {
      guard canChangeComposerOptions, availableComposerEfforts.contains(newValue) else { return }
      composerEffort = newValue
      composerPreferenceStore?.saveSelectedEffort(newValue)
      persistConversationArchive()
    }
  }

  var availableComposerEfforts: [AgentComposerEffort] {
    availableComposerModels.first(where: { $0.id.rawValue == resolvedComposerModelID })?
      .supportedEfforts ?? [.automatic]
  }

  var isComposerSelectionAvailable: Bool {
    availableComposerModels.contains(where: { $0.id.rawValue == resolvedComposerModelID })
      && availableComposerEfforts.contains(composerEffort)
  }

  func refreshAvailableModels() async {
    guard !isLoadingModels else { return }
    isLoadingModels = true
    let requestedModelID = modelID
    defer { isLoadingModels = false }
    do {
      let models = try await client.availableModels()
      guard requestedModelID == modelID else { return }
      discoveredModels = models
      modelCatalogNotice = nil
    } catch {
      guard requestedModelID == modelID else { return }
      discoveredModels = []
      modelCatalogNotice = "Model list could not refresh. The configured model is still available."
    }
  }

  var orderedConversations: [AgentConversation] {
    conversations.sorted {
      if $0.updatedAt == $1.updatedAt {
        return $0.id.uuidString < $1.id.uuidString
      }
      return $0.updatedAt > $1.updatedAt
    }
  }

  var isRunActive: Bool {
    if runTask != nil || isRecoveringRun || isPreparingAdmission || isLoadingConversation {
      return true
    }
    return switch runState {
    case .starting, .running, .waitingForAuthorization, .cancelling:
      true
    case .idle, .completed, .cancelled, .failed:
      false
    }
  }

  var canChangeComposerOptions: Bool {
    !isRunActive
  }

  var canSend: Bool {
    connectionState == .connected
      && !isRunActive
      && !conversations.contains(where: { $0.id == selectedConversationID && $0.isArchived })
      && !resolvedComposerModelID.isEmpty
      && isComposerSelectionAvailable
      && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var canRetryLastFailure: Bool {
    if connectionState == .disconnected {
      return true
    }
    return runState == .failed
      && isFailedRunRetryAvailable
      && currentRunRequest != nil
  }

  var runSummary: String {
    guard let currentRunID else {
      return runState.label
    }
    let shortID = String(currentRunID.rawValue.uuidString.prefix(8))
    return "\(runState.label) · \(shortID)"
  }

  var selectedConversationTitle: String? {
    guard let selectedConversationID else {
      return nil
    }
    return conversations.first(where: { $0.id == selectedConversationID })?.title
  }

  func connect() async {
    // Direct Connect/Retry is an explicit request; automatic entry points check this preference
    // before calling. A user Disconnect during the await below can suppress the late completion.
    automaticConnectionSuppressedByUser = false
    guard connectionState != .connected, connectionState != .connecting else {
      return
    }

    connectionState = .connecting
    activity = "Opening the gateway session…"
    errorMessage = nil

    do {
      let result = try await client.connect()
      guard !automaticConnectionSuppressedByUser else {
        try? await client.disconnect()
        connectionState = .disconnected
        gatewaySummary = "No gateway session"
        activity = "Disconnected."
        return
      }
      connectionState = .connected
      connectedGatewayInstanceID = result.response.gatewayInstanceID
      let sessionID = String(result.response.sessionID.rawValue.uuidString.prefix(8))
      gatewaySummary =
        "Session \(sessionID) · protocol \(result.response.selectedVersion.major).\(result.response.selectedVersion.minor)"
      if let executableID = result.response.executableID {
        gatewaySummary += " · agent build \(executableID.uuidString.prefix(8))"
      }
      activity = "Ready for a prompt."
      await refreshAvailableModels()
      if chatWorkspace == nil, usesPagedConversations, conversationPersistenceState.restoreFailed {
        didRestoreConversations = false
        await restoreConversationHistory()
      }
      scheduleRestoredRunRecovery()
    } catch is CancellationError {
      connectionState = .disconnected
      gatewaySummary = "No gateway session"
      activity = "Connection cancelled."
    } catch {
      connectionState = .disconnected
      gatewaySummary = "No gateway session"
      activity = "Connection failed."
      errorMessage = actionableMessage(
        for: error,
        context: "Could not connect to the gateway"
      )
    }
    // Activation can finish while an earlier connection is still failing. Consume its one pending
    // opportunity only after that attempt returns; an unsuccessful retry does not schedule another.
    let retryForActivation = residentActivationReconnectPending
    residentActivationReconnectPending = false
    if retryForActivation { await connectAutomatically() }
  }

  func connectFromControl() {
    Task { [weak self] in
      await self?.connect()
    }
  }

  func markGatewayDisconnected() {
    connectionState = .disconnected
    gatewaySummary = "Gateway connection interrupted"
  }

  func disconnectFromControl() {
    Task { [weak self] in
      await self?.disconnect()
    }
  }

  func disconnect() async {
    guard canDisconnect else {
      errorMessage = "Finish or cancel the active run before disconnecting."
      return
    }
    _ = cancelAutomaticDeliveryRecoveryForDisconnect()
    automaticConnectionSuppressedByUser = true
    residentActivationReconnectPending = false
    guard connectionState != .disconnected else { return }

    do {
      try await client.disconnect()
      connectionState = .disconnected
      gatewaySummary = "No gateway session"
      activity = "Disconnected."
    } catch is CancellationError {
      return
    } catch {
      errorMessage = actionableMessage(
        for: error,
        context: "Could not disconnect cleanly"
      )
    }
  }

  func retryLastFailure() {
    guard !isRunActive else { return }
    guard !conversations.contains(where: { $0.id == selectedConversationID && $0.isArchived })
    else {
      errorMessage = "Unarchive this conversation before retrying a request."
      return
    }
    guard
      runState == .failed,
      isFailedRunRetryAvailable,
      let failedRequest = currentRunRequest
    else {
      guard connectionState == .disconnected else {
        return
      }
      errorMessage = nil
      connectFromControl()
      return
    }

    let retryRequiresRecovery = !retryRequiresFreshRunID
    let request: GatewayStartRunRequest
    if retryRequiresFreshRunID {
      request = GatewayStartRunRequest(
        runID: AgentRunID(),
        modelID: failedRequest.modelID,
        initialMessages: failedRequest.initialMessages,
        options: failedRequest.options,
        toolChoice: failedRequest.toolChoice,
        workingDirectory: failedRequest.workingDirectory,
        availableArtifacts: failedRequest.availableArtifacts,
        authorizationMode: selectedComposerAuthorizationMode
      )
      guard beginRetryExchange(request, retryOf: failedRequest.runID) else { return }
      streamingAssistantItemID = nil
      currentRunHasToolEvidence = false
      currentAppliedSequence = 0
      currentFirstEventID = nil
      currentInvocationID = nil
      currentRunGatewayInstanceID = nil
      cancellationRequested = false
    } else {
      request = failedRequest
      updateHistoryOutcome(.inProgress)
    }

    currentRunID = request.runID
    currentRunRequest = request
    pendingInitialMessageIDs = Set(request.initialMessages.map(\.id))
    if !retryRequiresRecovery { resetAuthorizations() }
    isSubmittingAuthorization = false
    isFailedRunRetryAvailable = false
    retryRequiresFreshRunID = false
    needsRunRecovery = false
    errorMessage = nil
    runState = .starting
    activity = "Retrying the run…"

    runTask = Task { [weak self] in
      guard let self else { return }
      var handedOffToStartRun = false
      defer {
        if !handedOffToStartRun, currentRunID == request.runID { runTask = nil }
      }
      if connectionState != .connected {
        await connect()
      }
      guard currentRunID == request.runID else { return }
      guard connectionState == .connected else {
        runState = .failed
        isFailedRunRetryAvailable = true
        retryRequiresFreshRunID = !retryRequiresRecovery
        needsRunRecovery = retryRequiresRecovery
        updateHistoryOutcome(retryRequiresRecovery ? .interrupted : .failed)
        activity = "Run retry paused until the gateway reconnects."
        return
      }
      if retryRequiresRecovery {
        await recoverCurrentRun()
      } else if await saveCurrentRunCheckpoint() {
        handedOffToStartRun = true
        await startRun(request)
      } else {
        runState = .failed
        isFailedRunRetryAvailable = true
        retryRequiresFreshRunID = true
        updateHistoryOutcome(.failed)
        activity = "The retry was not sent because its recovery checkpoint could not be saved."
      }
    }
  }

  func dismissError() {
    errorMessage = nil
  }

  func send() {
    if isViewingEarlierTranscript, !isRunActive {
      Task { [weak self] in
        guard let self else { return }
        await loadLatestTranscript()
        if !isViewingEarlierTranscript { send() }
      }
      return
    }
    let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard connectionState == .connected else {
      errorMessage = "Connect to the gateway before sending a prompt."
      return
    }
    guard !isRunActive else {
      errorMessage = "Hex is already running. Cancel the current run before sending another prompt."
      return
    }
    guard !prompt.isEmpty else {
      errorMessage = "Enter a prompt before sending it to Hex."
      return
    }
    guard prompt.utf8.count <= AgentConversation.maximumPromptBytes else {
      errorMessage =
        "That prompt is too long. Keep it under \(AgentConversation.maximumPromptBytes) bytes."
      return
    }
    let selectedModelID = resolvedComposerModelID
    guard !selectedModelID.isEmpty else {
      errorMessage = "Configure a model in Resident setup before sending a prompt."
      return
    }
    guard isComposerSelectionAvailable else {
      errorMessage =
        "That model or effort is unavailable. Choose an available option in the composer."
      return
    }

    if let conversation = conversations.first(where: { $0.id == selectedConversationID }),
      conversation.hasUnresolvedHistory
    {
      errorMessage =
        "This conversation has an interrupted run or an unresolved tool action. Recover the original run first, or start a new conversation; Hex will not silently repeat that action."
      return
    }
    if let conversation = conversations.first(where: { $0.id == selectedConversationID }),
      conversation.hasContextToolIdentityCollision
    {
      errorMessage =
        "This conversation contains tool identifiers reused by separate runs. Its original history is preserved, but Hex cannot safely combine it for another request yet. Start a new conversation."
      return
    }
    let userMessage = Message(role: .user, content: [.text(prompt)])
    let newRunID = AgentRunID()
    guard canPersistPrompt(prompt, userMessage: userMessage, runID: newRunID) else { return }
    prepareAdmission(
      prompt: prompt, userMessage: userMessage, runID: newRunID,
      selectedModelID: selectedModelID)
  }

  var resolvedComposerModelID: String {
    selectedComposerModelID ?? modelID.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func cancel() {
    if isPreparingAdmission {
      runTask?.cancel()
      activity = "Stopping before dispatch…"
      return
    }
    guard !isRecoveringRun else {
      errorMessage = "Wait for the original task identity to be verified before cancelling it."
      return
    }
    guard canCancelRun, let runID = currentRunID, let invocationID = currentInvocationID else {
      errorMessage = "There is no active admitted run to cancel."
      return
    }

    runState = .cancelling
    isFailedRunRetryAvailable = false
    retryRequiresFreshRunID = false
    activity = "Requesting cancellation…"
    cancellationRequested = true
    let request = GatewayCancelRunRequest(runID: runID, invocationID: invocationID)
    Task { [weak self] in
      guard let self else { return }
      _ = await saveCurrentRunCheckpoint()
      guard currentRunID == runID, currentInvocationID == invocationID else { return }
      do {
        let response = try await client.cancelRun(request)
        guard currentRunID == runID, currentInvocationID == invocationID,
          currentRunRequest?.runID == runID
        else { return }
        switch response.disposition {
        case .requested:
          activity = "Cancellation requested."
        case .alreadyTerminal:
          activity = "The run had already finished."
        case .notFound:
          runState = .failed
          errorMessage = "The gateway no longer has this run. Reconnect before trying again."
        }
      } catch is CancellationError {
        return
      } catch {
        guard currentRunID == runID, currentInvocationID == invocationID,
          currentRunRequest?.runID == runID
        else { return }
        runState = .failed
        errorMessage = actionableMessage(for: error, context: "Could not cancel the run")
      }
    }
  }

  func decideAuthorization(_ choice: AuthorizationDecisionChoice) {
    guard let request = pendingAuthorization, !isSubmittingAuthorization else {
      return
    }

    let submissionID = UUID()
    authorizationSubmissionID = submissionID
    authorizationSubmittingRequestID = request.id
    isSubmittingAuthorization = true
    errorMessage = nil
    Task { [weak self] in
      guard let self else { return }
      do {
        try await client.decideAuthorization(request, choice: choice)
        guard currentRunID == request.runID, authorizationSubmissionID == submissionID else {
          return
        }
        if pendingAuthorizations.contains(where: { $0.id == request.id }) {
          submittedAuthorizationIDs.insert(request.id)
        }
        authorizationSubmissionID = nil
        isSubmittingAuthorization = false
        activity = "Submitted: \(choice.buttonTitle)."
      } catch is CancellationError {
        guard currentRunID == request.runID, authorizationSubmissionID == submissionID else {
          return
        }
        authorizationSubmissionID = nil
        isSubmittingAuthorization = false
      } catch {
        guard currentRunID == request.runID, authorizationSubmissionID == submissionID else {
          return
        }
        authorizationSubmissionID = nil
        isSubmittingAuthorization = false
        errorMessage = actionableMessage(
          for: error,
          context: "Could not submit the authorization decision"
        )
      }
    }
  }
}
