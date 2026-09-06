import Foundation
import HexCore
import HexGatewayKit
import HexIPC
import HexMCP
import Testing

@testable import Hex

@Suite(
  "Live resident agent integration",
  .serialized,
  .enabled(
    if: ProcessInfo.processInfo.environment["HEX_RUN_LIVE_AGENT_INTEGRATION"] == "1",
    "Set HEX_RUN_LIVE_AGENT_INTEGRATION=1 to exercise the signed resident gateway."
  ),
  .timeLimit(.minutes(5))
)
struct HexLiveResidentAgentIntegrationTests {
  private static let firstTurnReply = "HEX_LIVE_FIRST_TURN_OK"
  private static let secondTurnReply = "HEX_LIVE_SECOND_TURN_OK"
  private static let browserTurnReply = "HEX_LIVE_BROWSER_TURN_OK"
  private static let playwrightServerID = "playwright"
  private static let playwrightNavigateToolName = "mcp_10_playwright_browser_navigate"

  @Test
  func completesConversationHistoryAndAnInferenceDrivenBrowserTurn() async throws {
    let residentConfiguration = try await Self.withTimeout(
      seconds: 10,
      stage: "resident configuration"
    ) {
      try await HexGatewayResidentConfiguration.loadPersisted()
    }
    guard residentConfiguration.authorizationMode == .fullAccess else {
      throw LiveIntegrationError.fullAccessRequired
    }
    guard
      residentConfiguration.mcpClientSessions.contains(where: {
        $0.serverID == Self.playwrightServerID
      })
    else {
      throw LiveIntegrationError.playwrightUnavailable
    }

    let developerConfiguration = HexDeveloperConfiguration(
      environment: ProcessInfo.processInfo.environment
    )
    guard developerConfiguration.gatewayRoute.isResident else {
      throw LiveIntegrationError.residentRouteRequired
    }

    let client = HexLiveAgentClient(
      configuration: developerConfiguration,
      route: .residentXPC(machServiceName: residentConfiguration.machServiceName)
    )

    do {
      let connection = try await Self.withTimeout(seconds: 15, stage: "XPC handshake") {
        try await client.connect()
      }
      guard connection.response.activeRun == nil else {
        throw LiveIntegrationError.gatewayBusy
      }
      let firstUserMessage = Message(
        role: .user,
        content: [.text("Reply with exactly: \(Self.firstTurnReply)")]
      )
      let firstRun = try await Self.performRun(
        client: client,
        modelID: residentConfiguration.modelID,
        messages: [firstUserMessage],
        toolChoice: .automatic,
        timeoutSeconds: 60,
        stage: "first turn"
      )
      let firstAssistantMessage = try firstRun.requireFinalAssistantMessage(
        exactly: Self.firstTurnReply,
        stage: "first turn"
      )

      let models = try await Self.withTimeout(seconds: 15, stage: "model catalog") {
        try await client.availableModels()
      }
      let alternateModels = models.filter { $0.id.rawValue != residentConfiguration.modelID }
      guard
        let alternateModel = alternateModels.first(where: { $0.id.rawValue == "gpt-5.4-mini" })
          ?? alternateModels.first
      else {
        throw LiveIntegrationError.alternateModelUnavailable
      }
      let alternateEffort: InferenceReasoningEffort? =
        alternateModel.supportedReasoningEfforts?.contains(.low) == true
        ? .low
        : alternateModel.defaultReasoningEffort ?? alternateModel.supportedReasoningEfforts?.first
      let alternateOptions = InferenceOptions(reasoningEffort: alternateEffort)

      let secondUserMessage = Message(
        role: .user,
        content: [
          .text(
            "Use the preceding assistant message as conversation history. Reply with exactly: \(Self.secondTurnReply)"
          )
        ]
      )
      let secondRun = try await Self.performRun(
        client: client,
        modelID: alternateModel.id.rawValue,
        messages: [firstUserMessage, firstAssistantMessage, secondUserMessage],
        options: alternateOptions,
        timeoutSeconds: 60,
        stage: "second turn"
      )
      try secondRun.requireInferenceHistory(firstAssistantMessage, stage: "second turn")
      try secondRun.requireInferenceSelection(
        modelID: alternateModel.id,
        options: alternateOptions
      )
      _ = try secondRun.requireFinalAssistantMessage(
        exactly: Self.secondTurnReply,
        stage: "second turn"
      )

      // A named choice allows only this navigation in the first inference turn. Hex changes it
      // to .none after the tool result, so the replay round cannot choose another capability.
      let browserRun = try await Self.performRun(
        client: client,
        modelID: residentConfiguration.modelID,
        messages: [
          Message(
            role: .user,
            content: [
              .text(
                "Use \(Self.playwrightNavigateToolName) to open https://example.com. "
                  + "After its result confirms the page title is Example Domain, "
                  + "reply with exactly: \(Self.browserTurnReply)"
              )
            ]
          )
        ],
        toolChoice: .named(Self.playwrightNavigateToolName),
        timeoutSeconds: 90,
        stage: "model-browser-model round trip"
      )
      try browserRun.requireBrowserRoundTrip()
      _ = try browserRun.requireFinalAssistantMessage(
        exactly: Self.browserTurnReply,
        stage: "model-browser-model round trip"
      )

      try await Self.withTimeout(seconds: 10, stage: "disconnect") {
        try await client.disconnect()
      }
    } catch {
      try? await Self.withTimeout(seconds: 10, stage: "disconnect after failure") {
        try await client.disconnect()
      }
      throw error
    }
  }

  private static func performRun(
    client: HexLiveAgentClient,
    modelID: String,
    messages: [Message],
    options: InferenceOptions = InferenceOptions(),
    toolChoice: ToolChoice = .none,
    timeoutSeconds: Int,
    stage: String
  ) async throws -> LiveRunObservation {
    let runID = AgentRunID()
    let clock = ContinuousClock()
    let startedAt = clock.now
    do {
      return try await withTimeout(seconds: timeoutSeconds, stage: stage) {
        let response = try await client.startRun(
          GatewayStartRunRequest(
            runID: runID,
            modelID: ModelID(rawValue: modelID),
            initialMessages: messages,
            options: options,
            toolChoice: toolChoice
          )
        )
        guard case .started(let invocationID) = response.disposition else {
          if case .busy = response.disposition {
            throw LiveIntegrationError.gatewayBusy
          }
          throw LiveIntegrationError.runWasNotFresh(stage)
        }

        let stream = try await client.eventRecords(
          for: runID,
          invocationID: invocationID
        )
        var events: [AgentEvent] = []
        var firstTextAt: ContinuousClock.Instant?
        for try await envelope in stream {
          guard try await client.shouldApply(envelope) else {
            continue
          }
          events.append(envelope.record.event)
          if firstTextAt == nil,
            case .inferenceEvent(.textDelta(let text)) = envelope.record.event,
            !text.isEmpty
          {
            firstTextAt = clock.now
          }
          try await client.acknowledge(envelope)
        }

        let observation = LiveRunObservation(events: events)
        try observation.requireCompleted(stage: stage)
        let firstText = firstTextAt.map { String(describing: $0 - startedAt) } ?? "none"
        print(
          "HEX_LIVE_METRIC stage=\(stage) model=\(modelID) run=\(runID.rawValue) "
            + "first_text=\(firstText) elapsed=\(clock.now - startedAt) events=\(events.count)"
        )
        return observation
      }
    } catch {
      await cancelOwnedRunIfActive(client: client, runID: runID)
      throw error
    }
  }

  private static func cancelOwnedRunIfActive(
    client: HexLiveAgentClient,
    runID: AgentRunID
  ) async {
    await client.resetResidentGatewayConnection()
    let connection = try? await withTimeout(seconds: 5, stage: "cancellation handshake") {
      try await client.connect()
    }
    guard
      let connection,
      let activeRun = connection.response.activeRun,
      activeRun.runID == runID
    else {
      return
    }

    _ = try? await withTimeout(seconds: 5, stage: "remote cancellation") {
      try await client.cancelRun(
        GatewayCancelRunRequest(
          runID: runID,
          invocationID: activeRun.invocationID
        )
      )
    }
  }

  private static func withTimeout<Result: Sendable>(
    seconds: Int,
    stage: String,
    operation: @escaping @Sendable () async throws -> Result
  ) async throws -> Result {
    try await withThrowingTaskGroup(of: Result.self) { group in
      group.addTask {
        try await operation()
      }
      group.addTask {
        try await Task.sleep(for: .seconds(seconds))
        throw LiveIntegrationError.timedOut(stage)
      }

      guard let result = try await group.next() else {
        throw LiveIntegrationError.timedOut(stage)
      }
      group.cancelAll()
      return result
    }
  }

  private struct LiveRunObservation: Sendable {
    let events: [AgentEvent]

    func requireInferenceSelection(modelID: ModelID, options: InferenceOptions) throws {
      let requests = events.compactMap { event -> InferenceRequest? in
        guard case .inferenceRequested(let request) = event else { return nil }
        return request
      }
      guard !requests.isEmpty,
        requests.allSatisfy({ $0.modelID == modelID && $0.options == options })
      else {
        throw LiveIntegrationError.modelSelectionNotApplied
      }
    }

    func requireBrowserRoundTrip() throws {
      let calls = events.compactMap { event -> ToolCall? in
        guard case .toolStarted(let call) = event else { return nil }
        return call
      }
      guard calls.count == 1,
        let call = calls.first,
        call.name == HexLiveResidentAgentIntegrationTests.playwrightNavigateToolName,
        call.arguments == ["url": .string("https://example.com")]
      else {
        throw LiveIntegrationError.unexpectedBrowserToolCall
      }
      guard
        let result = events.compactMap({ event -> ToolResult? in
          guard case .toolFinished(let result) = event,
            result.toolCallID == call.id
          else { return nil }
          return result
        }).first,
        result.status == .success
      else {
        throw LiveIntegrationError.playwrightToolDidNotSucceed
      }
      guard
        result.content.contains(where: { content in
          guard case .text(let text) = content else { return false }
          return text.contains("Example Domain")
        })
      else {
        throw LiveIntegrationError.pageTitleMissingFromToolResult
      }

      let requests = events.compactMap { event -> InferenceRequest? in
        guard case .inferenceRequested(let request) = event else { return nil }
        return request
      }
      guard requests.count == 2,
        let replay = requests.last,
        replay.toolChoice == .none,
        replay.previousProviderResponseID != nil,
        replay.messages.contains(where: { message in
          message.role == .tool && message.content.contains(.toolResult(result))
        })
      else {
        throw LiveIntegrationError.missingBrowserReplay
      }
    }

    func requireCompleted(stage: String) throws {
      guard
        let terminalEvent = events.last(where: { event in
          switch event {
          case .runCompleted, .runCancelled, .runFailed:
            true
          default:
            false
          }
        })
      else {
        throw LiveIntegrationError.missingTerminal(stage)
      }

      switch terminalEvent {
      case .runCompleted:
        return
      case .runCancelled:
        throw LiveIntegrationError.runCancelled(stage)
      case .runFailed(let failure):
        throw LiveIntegrationError.runFailed(
          stage: stage,
          code: failure.code.rawValue,
          message: failure.message
        )
      default:
        throw LiveIntegrationError.missingTerminal(stage)
      }
    }

    func requireInferenceHistory(_ expected: Message, stage: String) throws {
      guard
        events.contains(where: { event in
          guard case .inferenceRequested(let request) = event else {
            return false
          }
          return request.messages.contains(expected)
        })
      else {
        throw LiveIntegrationError.missingHistoryMessage(stage)
      }
    }

    func requireFinalAssistantMessage(exactly expected: String, stage: String) throws -> Message {
      guard
        let message = events.reversed().compactMap({ event -> Message? in
          guard case .messageAppended(let message) = event, message.role == .assistant else {
            return nil
          }
          return message
        }).first
      else {
        throw LiveIntegrationError.missingAssistantMessage(stage)
      }
      guard Self.text(in: message) == expected else {
        throw LiveIntegrationError.unexpectedAssistantReply(stage)
      }
      return message
    }

    private static func text(in message: Message) -> String {
      message.content.compactMap { content in
        guard case .text(let text) = content else {
          return nil
        }
        return text
      }.joined()
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  private enum LiveIntegrationError: Error, LocalizedError, Sendable {
    case alternateModelUnavailable
    case fullAccessRequired
    case gatewayBusy
    case missingAssistantMessage(String)
    case missingBrowserReplay
    case missingHistoryMessage(String)
    case missingTerminal(String)
    case modelSelectionNotApplied
    case pageTitleMissingFromToolResult
    case playwrightToolDidNotSucceed
    case playwrightUnavailable
    case residentRouteRequired
    case runCancelled(String)
    case runFailed(stage: String, code: String, message: String)
    case runWasNotFresh(String)
    case timedOut(String)
    case unexpectedAssistantReply(String)
    case unexpectedBrowserToolCall

    var errorDescription: String? {
      switch self {
      case .alternateModelUnavailable:
        "The live model-switch lane requires two models in the resident's advertised catalog."
      case .fullAccessRequired:
        "The live integration lane requires Hex Full Access so no approval prompt can stall the headless test."
      case .gatewayBusy:
        "The resident gateway already has an active run; the live integration lane did not interfere with it."
      case .missingAssistantMessage(let stage):
        "The \(stage) completed without a final assistant message."
      case .missingBrowserReplay:
        "The browser result was not replayed into exactly one follow-up inference turn."
      case .missingHistoryMessage(let stage):
        "The \(stage) did not journal the prior assistant message supplied as conversation history."
      case .missingTerminal(let stage):
        "The \(stage) event stream ended without a terminal event."
      case .modelSelectionNotApplied:
        "The resident inference request did not use the selected model and reasoning effort."
      case .pageTitleMissingFromToolResult:
        "The successful Playwright result did not contain the Example Domain page title."
      case .playwrightToolDidNotSucceed:
        "The explicitly scoped Playwright navigation call did not report success."
      case .playwrightUnavailable:
        "Playwright is not enabled in the persisted resident configuration."
      case .residentRouteRequired:
        "The live integration lane requires the resident XPC gateway route."
      case .runCancelled(let stage):
        "The \(stage) was cancelled before completion."
      case .runFailed(let stage, let code, let message):
        "The \(stage) failed (\(code)): \(message)"
      case .runWasNotFresh(let stage):
        "The \(stage) did not begin as a fresh resident run."
      case .timedOut(let stage):
        "The \(stage) exceeded its bounded live-test timeout."
      case .unexpectedAssistantReply(let stage):
        "The \(stage) assistant reply did not match the required deterministic text."
      case .unexpectedBrowserToolCall:
        "The live run did not execute exactly the selected Example Domain navigation."
      }
    }
  }
}
