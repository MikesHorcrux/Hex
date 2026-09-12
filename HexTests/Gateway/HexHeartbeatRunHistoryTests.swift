import Foundation
import HexCore
import HexIPC
import Testing

@testable import Hex

@Suite("Readable scheduled run history")
struct HexHeartbeatRunHistoryTests {
  @Test
  func pageProjectionReconcilesNativeMessagesWithoutHidingBoundaryReceipts() {
    let runID = AgentRunID()
    let result = ToolResult(
      toolCallID: ToolCallID(), status: .failure,
      output: .object(["error": .string("not_executed")]), notExecutedReason: .runStopped)
    let records = Self.records(
      runID,
      events: [
        .inferenceEvent(.textDelta("Hel")), .inferenceEvent(.textDelta("lo")),
        .messageAppended(Message(role: .assistant, content: [.text("Hello, complete reply.")])),
        .toolFinished(result),
        .messageAppended(Message(role: .tool, content: [.toolResult(result)])),
      ])
    let projection = HexHeartbeatRunPageProjection(records: records)
    #expect(
      projection.items.map(\.text) == [
        "Hello, complete reply.", AgentMessagePresentation.toolResultText(result),
      ])
    #expect(!projection.hasPartialAssistantText)
    #expect(projection.items.last?.text.hasPrefix("Not run\n") == true)
    // Replacing pages must not hide a native receipt whose toolFinished was on the prior page.
    #expect(HexHeartbeatRunPageProjection(records: Array(records.suffix(1))).items.count == 1)
    #expect(
      HexHeartbeatRunPageProjection(records: Array(records.prefix(1))).hasPartialAssistantText)
  }

  @Test @MainActor
  func retainedResultRemainsBrowsableWithoutScheduleAndRefreshFailureKeepsRows() async throws {
    let client = HistoryClient()
    let model = HexHeartbeatRunHistoryModel(service: client, client: client)
    await model.refresh()
    let saved = try #require(model.runs.first)
    #expect(try await client.listHeartbeatSchedules().schedules.isEmpty)
    #expect(saved.scheduleName == "Removed morning check-in")
    #expect(model.selectedID == HexHeartbeatRunHistoryModel.identity(saved))
    await client.failList()
    await model.refresh()
    #expect(model.runs == [saved])
    #expect(model.errorMessage != nil)
    #expect(model.detail?.run == saved)
    #expect(await client.mutations == 0)
  }

  @Test @MainActor
  func opensLatestBoundedPageAndInvalidNextPagePreservesVisibleEvidence() async throws {
    let client = HistoryClient()
    let run = await client.savedRun
    let model = HexHeartbeatRunDetailModel(run: run, client: client)
    await model.refresh()
    #expect(model.pageStart == 48)
    #expect(model.pageEnd == 80)
    #expect(
      model.items.contains { $0.role == .assistant && $0.text == "Finished the background check." })
    #expect(!model.hasPartialAssistantText)
    #expect(!model.canGoNext)
    #expect(model.previousPageTitle == "First activity")
    await model.previousPage()
    #expect(model.pageStart == 0)
    #expect(model.pageEnd == 32)
    #expect(model.canGoNext)
    let savedItems = model.items
    await client.corruptPages()
    await model.nextPage()
    #expect(model.pageStart == 0)
    #expect(model.items == savedItems)
    #expect(model.errorMessage != nil)
    let requests = await client.historyRequests
    #expect(requests.map(\.afterSequence) == [48, 0, 32])
    #expect(requests.allSatisfy { $0.limit == 32 && $0.throughSequence == 80 })
    #expect(await client.mutations == 0)
  }

  @Test @MainActor
  func byteShortPagesUseVerifiedBoundariesAndFirstActivityHasNoGaps() async {
    let client = HistoryClient()
    await client.limitPageRecords(to: 5)
    let model = HexHeartbeatRunDetailModel(run: await client.savedRun, client: client)
    await model.refresh()
    #expect(model.pageStart == 48)
    #expect(model.pageEnd == 53)
    await model.nextPage()
    #expect(model.pageStart == 53)
    #expect(model.pageEnd == 58)
    #expect(model.previousPageTitle == "Previous activity")
    await model.previousPage()
    #expect(model.pageStart == 48)
    #expect(model.pageEnd == 53)
    #expect(model.previousPageTitle == "First activity")
    await model.previousPage()
    #expect(model.pageStart == 0)
    #expect(model.pageEnd == 5)
    #expect(!model.canGoBack)
    for start in stride(from: UInt64(5), through: UInt64(75), by: 5) {
      let previousEnd = model.pageEnd
      await model.nextPage()
      #expect(model.pageStart == start)
      #expect(model.pageStart == previousEnd)
      #expect(model.pageEnd == start + 5)
    }
    #expect(!model.canGoNext)
    #expect(model.items.contains { $0.text == "Finished the background check." })
    #expect(await client.mutations == 0)
  }

  @Test @MainActor
  func missingJournalRefreshClearsOldEvidenceAndNavigation() async {
    let client = HistoryClient()
    let model = HexHeartbeatRunDetailModel(run: await client.savedRun, client: client)
    await model.refresh()
    #expect(!model.items.isEmpty)
    #expect(model.canGoBack)
    await client.hideJournal()
    await model.refresh()
    #expect(model.items.isEmpty)
    #expect(model.pageStart == 0 && model.pageEnd == 0 && model.throughSequence == 0)
    #expect(!model.canGoBack && !model.canGoNext)
    #expect(!model.hasPartialAssistantText)
    #expect(model.hasLoaded)
    #expect(model.status.contains("unavailable"))
    #expect(await client.historyRequests.count == 1)
    #expect(await client.mutations == 0)
  }

  private nonisolated static func records(_ runID: AgentRunID, events: [AgentEvent])
    -> [AgentEventRecord]
  {
    events.enumerated().map { index, event in
      AgentEventRecord(
        id: AgentEventID(), runID: runID, sequence: UInt64(index + 1),
        timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)), event: event)
    }
  }

  private actor HistoryClient: HexAgentClient, HexHeartbeatManaging {
    let savedRun: GatewayHeartbeatRun
    let records: [AgentEventRecord]
    let instance = GatewayInstanceID()
    let storeID = UUID()
    var historyRequests: [GatewayRunHistoryRequest] = []
    var mutations = 0
    private var listFails = false
    private var pagesCorrupt = false
    private var pageRecordLimit = 32
    private var journalHidden = false

    init() {
      let runID = AgentRunID()
      savedRun = GatewayHeartbeatRun(
        scheduleID: UUID(), dueAt: Date(timeIntervalSince1970: 1_700_000_000),
        scheduleName: "Removed morning check-in", runID: runID)
      records = HexHeartbeatRunHistoryTests.records(
        runID,
        events: [.runStarted] + Array(repeating: .inferenceEvent(.textDelta("x")), count: 77)
          + [
            .messageAppended(
              Message(role: .assistant, content: [.text("Finished the background check.")])),
            .runCompleted,
          ])
    }
    func failList() { listFails = true }
    func corruptPages() { pagesCorrupt = true }
    func limitPageRecords(to count: Int) { pageRecordLimit = count }
    func hideJournal() { journalHidden = true }
    func listHeartbeatRuns(_ request: GatewayHeartbeatRunListRequest) async throws
      -> GatewayHeartbeatRunPage
    {
      if listFails { throw GatewayFailure(code: .disconnected, message: "Disconnected") }
      return GatewayHeartbeatRunPage(storeID: storeID, runs: [savedRun])
    }
    func listHeartbeatSchedules() async throws -> GatewayHeartbeatScheduleList {
      GatewayHeartbeatScheduleList(schedules: [])
    }
    func recoverRun(_ request: GatewayRunRecoveryRequest) async throws -> GatewayRunRecoveryResponse
    {
      if journalHidden {
        return GatewayRunRecoveryResponse(
          gatewayInstanceID: instance, runID: request.runID,
          disposition: .unknown)
      }
      let first = try #require(records.first)
      return GatewayRunRecoveryResponse(
        gatewayInstanceID: instance, runID: request.runID,
        disposition: .journaled(
          GatewayJournalRunSnapshot(
            runID: request.runID, firstEventID: first.id,
            latestSequence: 80, terminalRecord: records.last)))
    }
    func readRunHistory(_ request: GatewayRunHistoryRequest) async throws -> GatewayRunHistoryPage {
      historyRequests.append(request)
      let page = Array(
        records.filter { $0.sequence > request.afterSequence }
          .prefix(min(request.limit, pageRecordLimit)))
      let end = page.last?.sequence ?? request.afterSequence
      return GatewayRunHistoryPage(
        gatewayInstanceID: instance, runID: request.runID,
        firstEventID: pagesCorrupt ? AgentEventID() : request.firstEventID,
        afterSequence: request.afterSequence, throughSequence: request.throughSequence,
        records: page,
        nextAfterSequence: end < request.throughSequence ? end : nil)
    }
    func connect() async throws -> GatewayConnectionResult { throw unexpected() }
    func disconnect() async throws { throw unexpected() }
    func startRun(_ request: GatewayStartRunRequest) async throws -> GatewayStartRunResponse {
      throw unexpected()
    }
    func cancelRun(_ request: GatewayCancelRunRequest) async throws -> GatewayCancelRunResponse {
      throw unexpected()
    }
    func eventRecords(for runID: AgentRunID, invocationID: GatewayRunInvocationID) async throws
      -> AsyncThrowingStream<GatewayEventEnvelope, any Error>
    { throw unexpected() }
    func shouldApply(_ envelope: GatewayEventEnvelope) async throws -> Bool { throw unexpected() }
    func acknowledge(_ envelope: GatewayEventEnvelope) async throws { throw unexpected() }
    func decideAuthorization(_ request: AuthorizationRequest, choice: AuthorizationDecisionChoice)
      async throws
    { throw unexpected() }
    func addHeartbeatSchedule(_ request: GatewayHeartbeatScheduleRequest) async throws
      -> GatewayHeartbeatScheduleList
    { throw unexpected() }
    func removeHeartbeatSchedule(_ request: GatewayHeartbeatScheduleMutation) async throws
      -> GatewayHeartbeatScheduleList
    { throw unexpected() }
    func pauseHeartbeatSchedule(_ request: GatewayHeartbeatScheduleMutation) async throws
      -> GatewayHeartbeatScheduleList
    { throw unexpected() }
    func resumeHeartbeatSchedule(_ request: GatewayHeartbeatScheduleMutation) async throws
      -> GatewayHeartbeatScheduleList
    { throw unexpected() }
    private func unexpected() -> GatewayFailure {
      mutations += 1
      return GatewayFailure(
        code: .malformedPayload, message: "A read-only viewer attempted another operation.")
    }
  }
}
