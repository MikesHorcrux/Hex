import Foundation
import HexCore
import HexIPC
import Observation

@MainActor
@Observable
final class AgentWorkspaceModel {
  var transcript: [ConversationItem] = []
  var draft = ""
  var modelID: String
  private(set) var connectionState: AgentConnectionState = .disconnected
  var runState: AgentRunState = .idle
  var pendingAuthorization: AuthorizationRequest?
  var isSubmittingAuthorization = false
  var errorMessage: String?
  var activity = "Connect to a gateway to begin."
  private(set) var gatewaySummary = "No gateway session"
  private(set) var currentRunID: AgentRunID?

  let client: any HexAgentClient
  @ObservationIgnored var runTask: Task<Void, Never>?
  @ObservationIgnored var currentInvocationID: GatewayRunInvocationID?
  @ObservationIgnored var streamingAssistantItemID: UUID?

  init(client: any HexAgentClient, modelID: String = "preview") {
    self.client = client
    self.modelID = modelID
  }

  var isRunActive: Bool {
    switch runState {
    case .starting, .running, .waitingForAuthorization, .cancelling:
      true
    case .idle, .completed, .cancelled, .failed:
      false
    }
  }

  var canSend: Bool {
    connectionState == .connected
      && !isRunActive
      && !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var runSummary: String {
    guard let currentRunID else {
      return runState.label
    }
    let shortID = String(currentRunID.rawValue.uuidString.prefix(8))
    return "\(runState.label) · \(shortID)"
  }

  func connect() async {
    guard connectionState != .connected, connectionState != .connecting else {
      return
    }

    connectionState = .connecting
    activity = "Opening the gateway session…"
    errorMessage = nil

    do {
      let result = try await client.connect()
      connectionState = .connected
      let sessionID = String(result.response.sessionID.rawValue.uuidString.prefix(8))
      gatewaySummary =
        "Session \(sessionID) · protocol \(result.response.selectedVersion.major).\(result.response.selectedVersion.minor)"
      activity = "Ready for a prompt."
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
  }

  func connectFromControl() {
    Task { [weak self] in
      await self?.connect()
    }
  }

  func disconnectFromControl() {
    Task { [weak self] in
      await self?.disconnect()
    }
  }

  func disconnect() async {
    guard connectionState != .disconnected else {
      return
    }
    guard !isRunActive else {
      errorMessage = "Finish or cancel the active run before disconnecting."
      return
    }

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

  func retryConnection() {
    errorMessage = nil
    connectFromControl()
  }

  func dismissError() {
    errorMessage = nil
  }

  func send() {
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
    let selectedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !selectedModelID.isEmpty else {
      errorMessage = "Configure a model in Resident setup before sending a prompt."
      return
    }

    draft = ""
    errorMessage = nil
    currentRunID = AgentRunID()
    currentInvocationID = nil
    streamingAssistantItemID = nil
    pendingAuthorization = nil
    isSubmittingAuthorization = false
    runState = .starting
    activity = "Admitting the run…"
    transcript.append(
      ConversationItem(
        role: .user,
        text: prompt
      )
    )

    let runID = currentRunID
    guard let runID else {
      errorMessage = "Hex could not create a run identity. Try again."
      runState = .failed
      return
    }

    runTask = Task { [weak self] in
      await self?.startRun(
        prompt: prompt,
        modelID: selectedModelID,
        runID: runID
      )
    }
  }

  func cancel() {
    guard isRunActive, let runID = currentRunID, let invocationID = currentInvocationID else {
      errorMessage = "The run has not been admitted yet, so there is nothing to cancel."
      return
    }

    runState = .cancelling
    activity = "Requesting cancellation…"
    let request = GatewayCancelRunRequest(runID: runID, invocationID: invocationID)
    Task { [weak self] in
      guard let self else { return }
      do {
        let response = try await client.cancelRun(request)
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
        runState = .failed
        errorMessage = actionableMessage(for: error, context: "Could not cancel the run")
      }
    }
  }

  func decideAuthorization(_ choice: AuthorizationDecisionChoice) {
    guard let request = pendingAuthorization, !isSubmittingAuthorization else {
      return
    }

    isSubmittingAuthorization = true
    errorMessage = nil
    Task { [weak self] in
      guard let self else { return }
      do {
        try await client.decideAuthorization(request, choice: choice)
        isSubmittingAuthorization = false
        activity = "Submitted: \(choice.buttonTitle)."
      } catch is CancellationError {
        isSubmittingAuthorization = false
      } catch {
        isSubmittingAuthorization = false
        errorMessage = actionableMessage(
          for: error,
          context: "Could not submit the authorization decision"
        )
      }
    }
  }
}
