import Foundation
import HexCore
import HexIPC

extension AgentWorkspaceModel {
  func startRun(
    prompt: String,
    modelID: String,
    initialMessages: [Message],
    runID: AgentRunID
  ) async {
    let request = GatewayStartRunRequest(
      runID: runID,
      modelID: ModelID(rawValue: modelID),
      initialMessages: initialMessages
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
        for: error,
        context: "The gateway could not complete the run"
      )
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

  private func shortID(for runID: AgentRunID) -> String {
    String(runID.rawValue.uuidString.prefix(8))
  }
}
