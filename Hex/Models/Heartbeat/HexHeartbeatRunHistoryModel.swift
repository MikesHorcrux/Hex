import Foundation
import HexIPC
import Observation

@MainActor @Observable
final class HexHeartbeatRunHistoryModel {
  private(set) var runs: [GatewayHeartbeatRun] = []
  private(set) var nextCursor: GatewayHeartbeatRunCursor?
  private(set) var isLoading = false
  private(set) var hasLoaded = false
  private(set) var errorMessage: String?
  private(set) var scheduleID: UUID?
  private(set) var filterName: String?
  private(set) var selectedID: String?
  private(set) var detail: HexHeartbeatRunDetailModel?
  private let service: any HexHeartbeatManaging
  let client: any HexAgentClient
  private var generation = UUID()
  private var previousCursors: [GatewayHeartbeatRunCursor?] = []
  private var currentCursor: GatewayHeartbeatRunCursor?

  init(service: any HexHeartbeatManaging, client: any HexAgentClient) {
    self.service = service
    self.client = client
  }

  var canGoBack: Bool { !previousCursors.isEmpty && !isLoading }

  static func identity(_ run: GatewayHeartbeatRun) -> String {
    "\(run.scheduleID.uuidString):\(run.dueAt.timeIntervalSinceReferenceDate.bitPattern)"
  }

  func show(scheduleID: UUID? = nil, name: String? = nil) {
    generation = UUID()
    self.scheduleID = scheduleID
    filterName = name
    runs = []
    nextCursor = nil
    currentCursor = nil
    previousCursors = []
    selectedID = nil
    detail = nil
    errorMessage = nil
    isLoading = false
    hasLoaded = false
  }

  func select(_ id: String?) {
    guard id != selectedID else { return }
    selectedID = id
    detail = runs.first(where: { Self.identity($0) == id }).map {
      HexHeartbeatRunDetailModel(run: $0, client: client)
    }
  }

  func refresh() async {
    if await load(cursor: nil) { previousCursors = [] }
  }

  func loadOlder() async {
    guard let nextCursor, !isLoading else { return }
    let prior = currentCursor
    if await load(cursor: nextCursor) { previousCursors.append(prior) }
  }

  func loadNewer() async {
    guard canGoBack, let cursor = previousCursors.last else { return }
    if await load(cursor: cursor) { previousCursors.removeLast() }
  }

  private func load(cursor: GatewayHeartbeatRunCursor?) async -> Bool {
    guard !isLoading else { return false }
    let ticket = generation
    let request = GatewayHeartbeatRunListRequest(scheduleID: scheduleID, cursor: cursor, limit: 20)
    isLoading = true
    errorMessage = nil
    defer { if generation == ticket { isLoading = false } }
    do {
      let page = try await service.listHeartbeatRuns(request).validated(for: request)
      try Task.checkCancellation()
      guard generation == ticket else { return false }
      runs = page.runs
      nextCursor = page.nextCursor
      currentCursor = cursor
      hasLoaded = true
      // Keep an open result when refreshing or browsing another list page.
      if let selectedID, let updated = runs.first(where: { Self.identity($0) == selectedID }),
        detail?.run != updated
      {
        detail = HexHeartbeatRunDetailModel(run: updated, client: client)
      } else if selectedID == nil, let first = runs.first {
        select(Self.identity(first))
      }
      return true
    } catch is CancellationError { return false } catch {
      guard generation == ticket else { return false }
      errorMessage = "Couldn't load saved runs. \(error.localizedDescription)"
      return false
    }
  }
}
