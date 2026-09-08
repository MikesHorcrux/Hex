import Foundation
import HexCore
import HexRuntime
import Testing

@Suite("Runtime approval-mode lifecycle")
struct AgentRuntimeAuthorizationModeTests {
  @Test
  func explicitPolicyIsEstablishedBeforeInferenceAndEndedAfterCompletion() async throws {
    let journal = RecordingEventJournal()
    let authorization = RecordingPolicy(journal: journal)
    let provider = provider()
    let runtime = AgentRuntime(
      inferenceProvider: provider, toolExecutor: ScriptedToolExecutor(tools: []),
      authorizationProvider: authorization, journal: journal)
    let request = request(mode: .approveForMe)

    _ = try await runtime.run(request)

    #expect(await authorization.begunRuns() == [request.runID])
    #expect(await authorization.receivedModes() == [.approveForMe])
    #expect(await authorization.eventsAtBegin() == [.runStarted])
    #expect(await authorization.endedRuns() == [request.runID])
    #expect(await provider.requests().count == 1)
  }

  @Test
  func customProviderRejectsAnUnsupportedOverrideBeforeInferenceAndCleansOwnedScope() async throws {
    let journal = RecordingEventJournal()
    let authorization = ScriptedAuthorizationProvider()
    let provider = provider()
    let runtime = AgentRuntime(
      inferenceProvider: provider, toolExecutor: ScriptedToolExecutor(tools: []),
      authorizationProvider: authorization, journal: journal)
    let request = request(mode: .askEveryTime)

    do {
      _ = try await runtime.run(request)
      Issue.record("A provider without override support must not silently ignore Ask.")
    } catch AgentRuntimeError.authorizationFailure(let explanation) {
      #expect(explanation.contains("cannot apply conversation-specific permissions"))
    }

    #expect(await provider.requests().isEmpty)
    #expect(await authorization.endedRunIDs() == [request.runID])
    let events = await journal.events()
    #expect(events.count == 2)
    #expect(events.first == .runStarted)
    guard case .runFailed = events.last else {
      Issue.record("Unsupported policy must produce a failed terminal event.")
      return
    }
  }

  @Test
  func nilOverridePreservesExistingCustomProviders() async throws {
    let authorization = ScriptedAuthorizationProvider()
    let request = request(mode: nil)
    let runtime = AgentRuntime(
      inferenceProvider: provider(), toolExecutor: ScriptedToolExecutor(tools: []),
      authorizationProvider: authorization, journal: RecordingEventJournal())

    _ = try await runtime.run(request)

    #expect(await authorization.endedRunIDs() == [request.runID])
  }

  @Test
  func requestRoundTripsAllChoicesWithoutAddingModeToLegacyPayloads() throws {
    let encoder = JSONEncoder()
    let legacy = request(mode: nil)
    let legacyData = try encoder.encode(legacy)
    let legacyObject = try #require(
      JSONSerialization.jsonObject(with: legacyData) as? [String: Any])
    #expect(legacyObject["authorizationMode"] == nil)
    #expect(try JSONDecoder().decode(AgentRunRequest.self, from: legacyData) == legacy)
    for mode in HexAuthorizationMode.allCases {
      let current = request(mode: mode)
      #expect(
        try JSONDecoder().decode(AgentRunRequest.self, from: encoder.encode(current)) == current)
    }
    var unknown = legacyObject
    unknown["authorizationMode"] = "approve-everything-from-model-text"
    let unknownData = try JSONSerialization.data(withJSONObject: unknown)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(AgentRunRequest.self, from: unknownData)
    }
  }

  private func provider() -> ScriptedInferenceProvider {
    ScriptedInferenceProvider(
      descriptor: RuntimeTestFixture.descriptor(), models: [RuntimeTestFixture.model()],
      scripts: [.events(RuntimeTestFixture.textEvents())])
  }

  private func request(mode: HexAuthorizationMode?) -> AgentRunRequest {
    AgentRunRequest(
      runID: AgentRunID(), modelID: RuntimeTestFixture.modelID,
      initialMessages: [Message(role: .user, content: [.text("hello")])], authorizationMode: mode)
  }

  private actor RecordingPolicy: AuthorizationProvider {
    private let journal: RecordingEventJournal
    private var begun: [AgentRunID] = []
    private var modes: [HexAuthorizationMode?] = []
    private var ended: [AgentRunID] = []
    private var beginEvents: [AgentEvent] = []

    init(journal: RecordingEventJournal) { self.journal = journal }

    func beginRun(_ runID: AgentRunID, authorizationMode: HexAuthorizationMode?) async throws {
      beginEvents = await journal.events()
      begun.append(runID)
      modes.append(authorizationMode)
    }

    func authorize(_ request: AuthorizationRequest) async throws -> AuthorizationDecision { .allow }
    func endRun(_ runID: AgentRunID) async { ended.append(runID) }
    func begunRuns() -> [AgentRunID] { begun }
    func receivedModes() -> [HexAuthorizationMode?] { modes }
    func endedRuns() -> [AgentRunID] { ended }
    func eventsAtBegin() -> [AgentEvent] { beginEvents }
  }
}
