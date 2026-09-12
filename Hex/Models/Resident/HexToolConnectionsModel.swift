import Foundation
import HexIPC
import Observation

/// A live resident snapshot, deliberately separate from editable/saved integration settings.
@MainActor
@Observable
final class HexToolConnectionsModel {
  private(set) var servers: [GatewayToolServerStatus] = []
  private(set) var connectionState = AgentConnectionState.disconnected
  private(set) var isLoading = false
  private(set) var hasLoaded = false
  private(set) var notice: String?
  private(set) var needsReconnect = false
  private(set) var checkingServerIDs: Set<String> = []
  private(set) var rowNotices: [String: String] = [:]
  var isRunActive = false

  private let service: (any HexToolServerHealthServicing)?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var checks: [String: (id: UUID, task: Task<Void, Never>)] = [:]

  init(service: (any HexToolServerHealthServicing)? = nil) {
    self.service = service
  }

  var isSupported: Bool { service != nil }

  var canCheckConnections: Bool {
    isSupported && connectionState == .connected && !needsReconnect && !isRunActive && !isLoading
  }

  func connectionChanged(_ state: AgentConnectionState) {
    guard connectionState != state else { return }
    invalidateChecks()
    connectionState = state
    servers = []
    rowNotices = [:]
    isLoading = false
    hasLoaded = false
    needsReconnect = false
    notice = nil
  }

  /// This is read-only, including on first display: opening Settings cannot start an MCP server.
  func refresh() async {
    guard connectionState == .connected, let service else { return }
    invalidateChecks()
    let requestGeneration = generation
    isLoading = true
    notice = nil
    defer {
      if generation == requestGeneration { isLoading = false }
    }
    do {
      let health = try await service.toolServerHealth().validated()
      try Task.checkCancellation()
      guard isCurrent(requestGeneration) else { return }
      servers = health.servers.sorted { $0.serverID < $1.serverID }
      rowNotices = [:]
      hasLoaded = true
      needsReconnect = false
    } catch {
      guard isCurrent(requestGeneration) else { return }
      // A prior green badge is not evidence about a connection we can no longer inspect.
      servers = []
      rowNotices = [:]
      hasLoaded = false
      needsReconnect = Self.isConnectionFailure(error)
      notice =
        error is CancellationError
        ? "The status check was interrupted. Refresh to read the current connections."
        : (error as? GatewayFailure)?.code == .incompatibleProtocolVersion
          ? "Hex and Hex Agent use different protocol versions. Rebuild or update the canonical Hex app, then reconnect."
          : Self.safeReadFailure(needsReconnect: needsReconnect)
    }
  }

  func checkConnection(serverID: String) {
    guard canCheckConnections, let service, checks[serverID] == nil,
      servers.contains(where: { $0.serverID == serverID })
    else { return }
    let request = GatewayToolServerRequest(serverID: serverID)
    let requestGeneration = generation
    let id = UUID()
    checkingServerIDs.insert(serverID)
    rowNotices[serverID] = nil
    let task = Task { [weak self] in
      do {
        let status = try await service.refreshToolServer(request).validated(for: request)
        try Task.checkCancellation()
        guard let self, isCurrent(requestGeneration), checks[serverID]?.id == id else { return }
        if let index = servers.firstIndex(where: { $0.serverID == serverID }) {
          servers[index] = status
        }
      } catch {
        guard let self, isCurrent(requestGeneration), checks[serverID]?.id == id else { return }
        // Cancelling this observer does not prove that the resident's shared attempt stopped.
        rowNotices[serverID] =
          error is CancellationError
          ? "The check was interrupted; its outcome is not confirmed. Refresh status before trying again."
          : (error as? GatewayFailure)?.code == .toolMaintenanceInProgress
            ? "Hex Agent is working or another tool check is in progress. Finish the current task, then check again."
            : "The connection check could not be confirmed. Refresh status, then try again."
        if Self.isConnectionFailure(error) {
          servers = []
          hasLoaded = false
          needsReconnect = true
          notice = Self.safeReadFailure(needsReconnect: true)
        }
      }
      guard let self, isCurrent(requestGeneration), checks[serverID]?.id == id else { return }
      checks[serverID] = nil
      checkingServerIDs.remove(serverID)
    }
    checks[serverID] = (id, task)
  }

  func cancelCheck(serverID: String) {
    guard let check = checks.removeValue(forKey: serverID) else { return }
    check.task.cancel()
    checkingServerIDs.remove(serverID)
    rowNotices[serverID] =
      "Stopped waiting for the check; its outcome is not confirmed. Refresh status before trying again."
  }

  private func invalidateChecks() {
    generation = UUID()
    for check in checks.values { check.task.cancel() }
    checks.removeAll()
    checkingServerIDs.removeAll()
  }

  private func isCurrent(_ expectedGeneration: UUID) -> Bool {
    generation == expectedGeneration && connectionState == .connected
  }

  private static func isConnectionFailure(_ error: any Error) -> Bool {
    guard let failure = error as? GatewayFailure else { return false }
    switch failure.code {
    case .notConnected, .staleSession, .disconnected, .transportUnavailable: return true
    default: return false
    }
  }

  private static func safeReadFailure(needsReconnect: Bool) -> String {
    needsReconnect
      ? "The Hex Agent connection is unavailable. Connect again to read its tool status."
      : "Tool status could not be verified. Refresh to try again; saved tool choices are unchanged."
  }
}
