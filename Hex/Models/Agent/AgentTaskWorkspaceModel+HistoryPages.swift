import Foundation
import HexCore
import HexIPC

extension AgentTaskWorkspaceModel {
  func selectAttempt(_ id: AgentRunID?) {
    historicalRunID = id
    observedRunID = nil
    sequence = 0
    hasInference = false
    items = []
    approvals = []
    observationGeneration = UUID()
    inspectingHistory = false
    historyPageStarts = []
  }

  func historyPage(after: UInt64) async {
    guard let runID = historicalRunID ?? selected?.runID else { return }
    inspectingHistory = true
    observationGeneration = UUID()
    let generation = observationGeneration
    do {
      let response = try await client.recoverRun(.init(runID: runID))
      let snapshot: GatewayJournalRunSnapshot?
      switch response.disposition {
      case .resident(_, _, let journal): snapshot = journal
      case .journaled(let journal): snapshot = journal
      case .unknown: snapshot = nil
      }
      guard let snapshot, generation == observationGeneration else { return }
      let page = try await client.readRunHistory(
        .init(
          runID: runID,
          firstEventID: snapshot.firstEventID, afterSequence: after,
          throughSequence: snapshot.latestSequence, limit: 32))
      guard generation == observationGeneration else { return }
      items = []
      approvals = []
      hasInference = true
      for record in page.records { applyTaskRecord(record) }
      approvals = []
      sequence = page.records.last?.sequence ?? after
      historyHasMore = sequence < snapshot.latestSequence
      if historyPageStarts.last != after { historyPageStarts.append(after) }
    } catch {
      self.error = "Could not read this saved history page. Original records were retained."
    }
  }

  func previousHistoryPage() async {
    guard historyPageStarts.count > 1 else { return }
    historyPageStarts.removeLast()
    if let start = historyPageStarts.last { await historyPage(after: start) }
  }

  func olderAttempts() async {
    guard let selectedID, let before = attempts.last?.number, before > 1 else { return }
    do {
      let response = try await taskClient.taskOperation(
        .attempts(selectedID, before: before, limit: 20))
      attempts += response.attempts.filter { value in !attempts.contains { $0.id == value.id } }
    } catch { self.error = "Could not read earlier attempt links." }
  }
}
