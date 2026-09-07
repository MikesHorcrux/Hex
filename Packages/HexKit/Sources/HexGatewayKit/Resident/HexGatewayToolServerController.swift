import HexCore
import HexIPC
import HexMCP

/// Maps the running resident's enabled tool servers to bounded, secret-free control-plane values.
/// Installation, saved settings, Mac privacy grants and successful task execution are separate facts.
public actor HexGatewayToolServerController {
  private let executors: [String: MCPManagedToolExecutor]
  private let transports: [String: HexResidentMCPTransport]

  public init(
    executors: [MCPManagedToolExecutor], settings: [HexResidentMCPServerSettings] = []
  ) throws {
    guard executors.count <= 16,
      Set(executors.map(\.serverID)).count == executors.count
    else {
      throw GatewayFailure(
        code: .malformedPayload, message: "Tool connections contain invalid server identities.")
    }
    for executor in executors {
      _ = try GatewayToolServerRequest(serverID: executor.serverID).validated()
    }
    self.executors = Dictionary(uniqueKeysWithValues: executors.map { ($0.serverID, $0) })
    let enabledSettings = settings.filter(\.isEnabled)
    guard Set(enabledSettings.map(\.serverID)).count == enabledSettings.count,
      Set(enabledSettings.map(\.serverID)).isSubset(of: Set(executors.map(\.serverID)))
    else {
      throw GatewayFailure(
        code: .malformedPayload, message: "Tool configuration does not match the running servers.")
    }
    transports = Dictionary(
      uniqueKeysWithValues: enabledSettings.map { ($0.serverID, $0.transport) })
  }

  /// Does not connect, refresh a catalog, request a permission, or execute any tool.
  public func health() async throws -> GatewayToolServerHealth {
    var servers: [GatewayToolServerStatus] = []
    for id in executors.keys.sorted() {
      guard let executor = executors[id] else { continue }
      servers.append(try await status(of: executor))
    }
    return try GatewayToolServerHealth(servers: servers).validated()
  }

  /// The caller owns the service's idle-maintenance gate for this entire connection attempt.
  public func refresh(_ request: GatewayToolServerRequest) async throws -> GatewayToolServerStatus {
    let request = try request.validated()
    guard let executor = executors[request.serverID] else {
      throw GatewayFailure(
        code: .malformedPayload,
        message: "That tool connection is not enabled in the running Hex Agent.")
    }
    do {
      try await executor.refreshCatalog()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      // The managed executor owns sanitized failure classification. Never forward server output,
      // credential-bearing endpoints, local environment values or arbitrary Error descriptions.
    }
    try Task.checkCancellation()
    return try await status(of: executor)
  }

  private func status(of executor: MCPManagedToolExecutor) async throws -> GatewayToolServerStatus {
    let snapshot = await executor.healthSnapshot()
    let state: GatewayToolServerState
    switch snapshot.state {
    case .disconnected: state = .disconnected
    case .connecting: state = .connecting
    case .ready: state = .ready
    case .unavailable: state = .unavailable
    }
    let failure: GatewayToolServerFailure?
    switch snapshot.failure {
    case .componentMissing: failure = .componentMissing
    case .configurationInvalid: failure = .configurationInvalid
    case .connectionTimedOut: failure = .connectionTimedOut
    case .serverRejected: failure = .serverRejected
    case .invalidResponse: failure = .invalidResponse
    case .connectionFailed: failure = .connectionFailed
    case nil: failure = nil
    }
    return try GatewayToolServerStatus(
      serverID: snapshot.serverID, state: state, failure: failure,
      availableToolCount: snapshot.availableToolCount, transport: transports[snapshot.serverID]
    ).validated()
  }
}
