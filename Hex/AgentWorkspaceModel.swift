import Foundation
import HexCore
import HexIPC
import Observation

@MainActor
@Observable
final class AgentWorkspaceModel {
  enum ConnectionState: String, Sendable {
    case disconnected
    case connecting
    case connected

    var label: String {
      switch self {
      case .disconnected:
        "Disconnected"
      case .connecting:
        "Connecting"
      case .connected:
        "Connected"
      }
    }
  }

  enum RunState: String, Sendable {
    case idle
    case starting
    case running
    case waitingForAuthorization
    case cancelling
    case completed
    case cancelled
    case failed

    var label: String {
      switch self {
      case .idle:
        "Ready"
      case .starting:
        "Starting"
      case .running:
        "Running"
      case .waitingForAuthorization:
        "Waiting for approval"
      case .cancelling:
        "Stopping"
      case .completed:
        "Completed"
      case .cancelled:
        "Cancelled"
      case .failed:
        "Failed"
      }
    }

    var isTerminal: Bool {
      switch self {
      case .completed, .cancelled, .failed:
        true
      case .idle, .starting, .running, .waitingForAuthorization, .cancelling:
        false
      }
    }
  }

  var transcript: [ConversationItem] = []
  var draft = ""
  var modelID: String
  private(set) var connectionState: ConnectionState = .disconnected
  private(set) var runState: RunState = .idle
  private(set) var pendingAuthorization: AuthorizationRequest?
  private(set) var isSubmittingAuthorization = false
  private(set) var errorMessage: String?
  private(set) var activity = "Connect to a gateway to begin."
  private(set) var gatewaySummary = "No gateway session"
  private(set) var currentRunID: AgentRunID?

  private let client: any HexAgentClient
  @ObservationIgnored private var runTask: Task<Void, Never>?
  @ObservationIgnored private var currentInvocationID: GatewayRunInvocationID?
  @ObservationIgnored private var streamingAssistantItemID: UUID?

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
    let selectedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
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

  private func startRun(
    prompt: String,
    modelID: String,
    runID: AgentRunID
  ) async {
    let message = Message(role: .user, content: [.text(prompt)])
    let request = GatewayStartRunRequest(
      runID: runID,
      modelID: ModelID(rawValue: modelID),
      initialMessages: [message]
    )

    do {
      let response = try await client.startRun(request)
      guard currentRunID == runID else { return }

      let invocationID: GatewayRunInvocationID
      switch response.disposition {
      case .started(let admittedInvocationID),
        .alreadyRunning(let admittedInvocationID),
        .alreadyTerminal(let admittedInvocationID):
        invocationID = admittedInvocationID
      case .busy(let activeRunID):
        runState = .failed
        activity = "Run admission blocked."
        errorMessage =
          "Another run is active (\(shortID(for: activeRunID))). Wait for it to finish or cancel it, then retry."
        return
      }

      currentInvocationID = invocationID
      if case .alreadyTerminal = response.disposition {
        runState = .completed
        activity = "Showing the remembered terminal run."
      } else {
        runState = .running
        activity = "Streaming from the gateway…"
      }

      let stream = try await client.eventRecords(for: runID, invocationID: invocationID)
      for try await envelope in stream {
        guard currentRunID == runID else { return }
        guard try await client.shouldApply(envelope) else { continue }
        apply(envelope.record)
        try await client.acknowledge(envelope)
      }
    } catch is CancellationError {
      guard currentRunID == runID else { return }
      if !runState.isTerminal {
        runState = .cancelled
        activity = "Run cancelled."
        finishStreamingAssistant()
      }
    } catch {
      guard currentRunID == runID else { return }
      runState = .failed
      activity = "Run stopped."
      finishStreamingAssistant()
      errorMessage = actionableMessage(
        for: error, context: "The gateway could not complete the run")
    }

    if currentRunID == runID {
      runTask = nil
    }
  }

  private func apply(_ record: AgentEventRecord) {
    switch record.event {
    case .runStarted:
      runState = .running
      activity = "Agent started."

    case .messageAppended(let message):
      append(message)

    case .inferenceRequested(let request):
      activity = "Thinking with \(request.modelID.rawValue)…"

    case .inferenceEvent(let event):
      applyInferenceEvent(event)

    case .authorizationRequested(let request):
      pendingAuthorization = request
      isSubmittingAuthorization = false
      runState = .waitingForAuthorization
      let resource = request.resource.map { " · \($0)" } ?? ""
      activity = "Approval needed for \(request.operation)\(resource)."
      appendEvent("Approval requested · \(request.capability.rawValue)")

    case .authorizationDecided(_, let decision):
      pendingAuthorization = nil
      isSubmittingAuthorization = false
      runState = .running
      switch decision {
      case .allow:
        activity = "Approval granted."
        appendEvent("Approval granted")
      case .deny(let reason):
        activity = "Approval denied."
        appendEvent(reason.map { "Approval denied · \($0)" } ?? "Approval denied")
      }

    case .toolStarted(let call):
      activity = "Running \(call.name)…"
      appendTool("Started \(call.name)")

    case .toolFinished(let result):
      activity = result.status == .success ? "Tool finished." : "Tool failed."
      appendTool(toolResultText(result))

    case .runCompleted:
      runState = .completed
      activity = "Completed successfully."
      finishStreamingAssistant()

    case .runCancelled:
      runState = .cancelled
      activity = "Cancelled."
      finishStreamingAssistant()

    case .runFailed(let failure):
      runState = .failed
      activity = "Run failed."
      finishStreamingAssistant()
      errorMessage = "Run failed (\(failure.code.rawValue)): \(failure.message)"
    }
  }

  private func applyInferenceEvent(_ event: InferenceStreamEvent) {
    switch event {
    case .started:
      activity = "Provider connected."
    case .textDelta(let text):
      appendAssistantDelta(text)
      activity = "Streaming assistant response…"
    case .reasoningSummaryDelta:
      activity = "Reasoning…"
    case .toolCall(let call):
      activity = "Preparing \(call.name)…"
    case .usage(let usage):
      activity = "Used \(usage.outputTokens) output tokens."
    case .completed(let reason):
      activity = "Inference finished (\(stopReasonLabel(reason)))."
    }
  }

  private func append(_ message: Message) {
    let text = messageText(message)
    guard !text.isEmpty else { return }

    switch message.role {
    case .user:
      guard !(transcript.last?.role == .user && transcript.last?.text == text) else { return }
      transcript.append(ConversationItem(role: .user, text: text))
    case .assistant:
      if let streamingAssistantItemID,
        let index = transcript.firstIndex(where: { $0.id == streamingAssistantItemID })
      {
        transcript[index].text = text
        transcript[index].isStreaming = false
        self.streamingAssistantItemID = nil
      } else {
        transcript.append(ConversationItem(role: .assistant, text: text))
      }
    case .tool:
      transcript.append(ConversationItem(role: .tool, text: text))
    case .system, .developer:
      transcript.append(ConversationItem(role: .event, text: text))
    }
  }

  private func appendAssistantDelta(_ text: String) {
    guard !text.isEmpty else { return }
    if let streamingAssistantItemID,
      let index = transcript.firstIndex(where: { $0.id == streamingAssistantItemID })
    {
      transcript[index].text.append(text)
      return
    }

    let item = ConversationItem(role: .assistant, text: text, isStreaming: true)
    streamingAssistantItemID = item.id
    transcript.append(item)
  }

  private func finishStreamingAssistant() {
    guard let streamingAssistantItemID,
      let index = transcript.firstIndex(where: { $0.id == streamingAssistantItemID })
    else {
      return
    }
    transcript[index].isStreaming = false
    self.streamingAssistantItemID = nil
  }

  private func appendEvent(_ text: String) {
    transcript.append(ConversationItem(role: .event, text: text))
  }

  private func appendTool(_ text: String) {
    transcript.append(ConversationItem(role: .tool, text: text))
  }

  private func messageText(_ message: Message) -> String {
    message.content.compactMap { content in
      switch content {
      case .text(let text):
        text
      case .toolCall(let call):
        "Tool call · \(call.name)"
      case .toolResult(let result):
        toolResultText(result)
      case .image:
        "[Image]"
      }
    }
    .joined(separator: "\n")
  }

  private func toolResultText(_ result: ToolResult) -> String {
    let status = result.status == .success ? "Succeeded" : "Failed"
    let output = jsonText(result.output)
    return "\(status) · \(output)"
  }

  private func jsonText(_ value: JSONValue) -> String {
    switch value {
    case .null:
      return "null"
    case .boolean(let value):
      return value ? "true" : "false"
    case .integer(let value):
      return String(value)
    case .number(let value):
      return String(value)
    case .string(let value):
      return value
    case .array(let values):
      return "[" + values.map(jsonText).joined(separator: ", ") + "]"
    case .object(let values):
      let pairs: [String] = values.keys.sorted().compactMap { (key: String) -> String? in
        guard let value = values[key] else { return nil }
        return "\(key): \(jsonText(value))"
      }
      return "{" + pairs.joined(separator: ", ") + "}"
    }
  }

  private func stopReasonLabel(_ reason: InferenceStopReason) -> String {
    switch reason {
    case .stop:
      "stop"
    case .toolCalls:
      "tool calls"
    case .length:
      "length limit"
    case .contentFilter:
      "content filter"
    case .other(let value):
      value
    }
  }

  private func shortID(for runID: AgentRunID) -> String {
    String(runID.rawValue.uuidString.prefix(8))
  }

  private func actionableMessage(for error: any Error, context: String) -> String {
    if let failure = error as? GatewayFailure {
      let remedy =
        failure.isRetryable
        ? "Try reconnecting, then retry the run."
        : "Check the gateway configuration and try again."
      return "\(context): \(failure.message) \(remedy)"
    }
    return "\(context): \(error.localizedDescription). Check the gateway and try again."
  }
}
