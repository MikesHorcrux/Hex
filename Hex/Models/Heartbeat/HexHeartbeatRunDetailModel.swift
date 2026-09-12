import Foundation
import HexCore
import HexIPC
import Observation

@MainActor @Observable
final class HexHeartbeatRunDetailModel {
  let id = UUID()
  let run: GatewayHeartbeatRun
  let client: any HexAgentClient
  private(set) var items: [ConversationItem] = []
  private(set) var isLoading = false
  private(set) var hasLoaded = false
  private(set) var errorMessage: String?
  private(set) var status = "Checking saved run…"
  private(set) var pageStart: UInt64 = 0
  private(set) var pageEnd: UInt64 = 0
  private(set) var throughSequence: UInt64 = 0
  private(set) var hasPartialAssistantText = false
  private var anchor: GatewayJournalRunSnapshot?
  private var instanceID: GatewayInstanceID?
  private var nextSequence: UInt64?
  // Cursor metadata only; the visible page is the sole cached record payload.
  private var previousPageStarts: [UInt64] = []
  private var generation = UUID()
  private let pageSize: UInt64 = 32

  init(run: GatewayHeartbeatRun, client: any HexAgentClient) {
    self.run = run
    self.client = client
  }

  var canGoBack: Bool { anchor != nil && pageStart > 0 && !isLoading }
  var canGoNext: Bool { nextSequence != nil && !isLoading }
  var previousPageTitle: String {
    previousPageStarts.isEmpty ? "First activity" : "Previous activity"
  }

  func refresh() async {
    guard !isLoading else { return }
    guard let runID = run.runID else {
      clearPage()
      status = "No linked run was recorded for this occurrence."
      hasLoaded = true
      return
    }
    let ticket = UUID()
    generation = ticket
    isLoading = true
    errorMessage = nil
    defer { if generation == ticket { isLoading = false } }
    do {
      let request = GatewayRunRecoveryRequest(runID: runID)
      let response = try await client.recoverRun(request).validated(for: request)
      try Task.checkCancellation()
      guard generation == ticket else { return }
      let snapshot: GatewayJournalRunSnapshot?
      let observedStatus: String
      switch response.disposition {
      case .resident(let resident, _, let journal):
        snapshot = journal
        observedStatus =
          journal?.terminalRecord.map { Self.terminalStatus($0.event) }
          ?? "Resident run · \(resident.phase.rawValue)"
      case .journaled(let journal):
        snapshot = journal
        observedStatus =
          journal.terminalRecord.map { Self.terminalStatus($0.event) }
          ?? "No terminal outcome was recorded. This does not mean the run is still active."
      case .unknown:
        snapshot = nil
        observedStatus = "Saved run history is unavailable. No work has been repeated."
      }
      guard let snapshot, snapshot.latestSequence > 0 else {
        clearPage()
        status = observedStatus
        hasLoaded = true
        return
      }
      if let expected = run.journal {
        guard snapshot.firstEventID == expected.firstEventID,
          snapshot.latestSequence == expected.terminalSequence
        else {
          throw GatewayFailure(
            code: .invalidCursor,
            message: "The saved journal no longer matches this occurrence's original run.")
        }
      }
      let start = snapshot.latestSequence > pageSize ? snapshot.latestSequence - pageSize : 0
      let page = try await readPage(
        snapshot: snapshot, instance: response.gatewayInstanceID, after: start)
      try Task.checkCancellation()
      guard generation == ticket else { return }
      anchor = snapshot
      instanceID = response.gatewayInstanceID
      status = observedStatus
      previousPageStarts = []
      apply(page)
    } catch is CancellationError { return } catch {
      errorMessage = "Couldn't read saved activity. \(error.localizedDescription)"
    }
  }

  func previousPage() async {
    guard canGoBack else { return }
    if let previous = previousPageStarts.last {
      await loadPage(after: previous, previousStarts: Array(previousPageStarts.dropLast()))
    } else {
      // The latest-tail entry point has no known preceding page. Start at the beginning,
      // then follow verified exclusive cursors; subtracting an event count skips short pages.
      await loadPage(after: 0, previousStarts: [])
    }
  }

  func nextPage() async {
    guard canGoNext, let nextSequence else { return }
    await loadPage(
      after: nextSequence,
      previousStarts: Array((previousPageStarts + [pageStart]).suffix(128)))
  }

  private func loadPage(after sequence: UInt64, previousStarts: [UInt64]) async {
    guard !isLoading, let anchor, let instanceID else { return }
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      let page = try await readPage(snapshot: anchor, instance: instanceID, after: sequence)
      try Task.checkCancellation()
      previousPageStarts = previousStarts
      apply(page)
    } catch is CancellationError { return } catch {
      errorMessage = "Couldn't read this activity page. \(error.localizedDescription)"
    }
  }

  private func readPage(
    snapshot: GatewayJournalRunSnapshot, instance: GatewayInstanceID, after: UInt64
  )
    async throws -> GatewayRunHistoryPage
  {
    let request = GatewayRunHistoryRequest(
      runID: snapshot.runID, firstEventID: snapshot.firstEventID,
      afterSequence: after, throughSequence: snapshot.latestSequence, limit: Int(pageSize))
    let page = try await client.readRunHistory(request).validated(for: request)
    guard page.gatewayInstanceID == instance else {
      throw GatewayFailure(
        code: .staleSession,
        message: "Hex Agent changed. Refresh the saved run before reading more.")
    }
    return page
  }

  private func apply(_ page: GatewayRunHistoryPage) {
    let projection = HexHeartbeatRunPageProjection(records: page.records)
    items = projection.items
    hasPartialAssistantText = projection.hasPartialAssistantText
    pageStart = page.afterSequence
    pageEnd = page.records.last?.sequence ?? page.afterSequence
    throughSequence = page.throughSequence
    nextSequence = page.nextAfterSequence
    hasLoaded = true
  }

  private func clearPage() {
    items = []
    hasPartialAssistantText = false
    anchor = nil
    instanceID = nil
    nextSequence = nil
    previousPageStarts = []
    pageStart = 0
    pageEnd = 0
    throughSequence = 0
  }

  private static func terminalStatus(_ event: AgentEvent) -> String {
    switch event {
    case .runCompleted: "Run completed."
    case .runCancelled: "Run cancelled."
    case .runFailed(let failure): "Run failed · \(failure.message)"
    default: "Terminal outcome unavailable."
    }
  }
}
