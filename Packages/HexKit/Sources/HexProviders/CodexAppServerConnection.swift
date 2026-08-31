import Foundation
import HexCore

/// Bounded JSONL connection for the stable Codex app-server protocol.
public actor CodexAppServerConnection: CodexAppServerTransport {
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
  ) throws {
    guard state == .disconnected, notificationHandler == nil else {
      throw CodexAppServerConnectionError.alreadyConnected
    }
    notificationHandler = handler
  }

  public func send(_ request: CodexAppServerRequest) async throws -> JSONValue {
    guard state == .ready else {
      throw CodexAppServerConnectionError.connectionClosed
    }
    return try await requestResult(
      method: request.method,
      parameters: request.parameters,
      generation: generation,
      permittedState: .ready
    )
  }
}
