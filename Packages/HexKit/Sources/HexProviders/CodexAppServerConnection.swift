import Foundation
import HexCore

/// Bounded JSONL connection for the stable Codex app-server protocol.
public actor CodexAppServerConnection: CodexAppServerTransport {
  public nonisolated let accountLoginFlowGeneration =
    CodexAccountLoginFlowGenerationController()
  let configuration: CodexAppServerConnectionConfiguration
  let channel: any CodexAppServerChannel
  var notificationHandler: (any CodexAppServerNotificationHandler)?
  var state = CodexAppServerConnectionState.disconnected
  var generation = UInt64(0)
  var establishmentGeneration: UInt64?
  var nextRequestID = Int64(1)
  var pendingRequests: [Int64: CodexAppServerPendingRequest] = [:]
  var outputBuffer = Data()
  var readerTask: Task<Void, Never>?
  var shutdown: CodexAppServerConnectionShutdown?
  var generationRetirementStarted = false
  var generationRetirementFinished = false
  var generationRetirementWaiters: [CheckedContinuation<Void, Never>] = []
  var establishmentWaiters: [CheckedContinuation<Void, Never>] = []

  public init(
    configuration: CodexAppServerConnectionConfiguration,
    channel: any CodexAppServerChannel,
    notificationHandler: (any CodexAppServerNotificationHandler)? = nil
  ) {
    self.configuration = configuration
    self.channel = channel
    self.notificationHandler = notificationHandler
  }

  public func installNotificationHandler(
    _ handler: any CodexAppServerNotificationHandler
  ) async throws {
    guard !generationRetirementStarted else {
      throw CodexAppServerConnectionError.connectionClosed
    }
    try await ensureAccountLoginFlowGenerationIsUsable()
    guard !generationRetirementStarted else {
      throw CodexAppServerConnectionError.connectionClosed
    }
    guard state == .disconnected, notificationHandler == nil else {
      throw CodexAppServerConnectionError.alreadyConnected
    }
    notificationHandler = handler
  }

  public func send(_ request: CodexAppServerRequest) async throws -> JSONValue {
    guard !generationRetirementStarted else {
      throw CodexAppServerConnectionError.connectionClosed
    }
    try await ensureAccountLoginFlowGenerationIsUsable()
    guard !generationRetirementStarted, state == .ready else {
      throw CodexAppServerConnectionError.connectionClosed
    }
    return try await requestResult(
      method: request.method,
      parameters: request.parameters,
      generation: generation,
      permittedState: .ready
    )
  }

  func ensureAccountLoginFlowGenerationIsUsable() async throws {
    do {
      try await accountLoginFlowGeneration.ensureUsable()
    } catch {
      throw CodexAppServerConnectionError.connectionClosed
    }
  }
}
