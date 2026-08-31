import Foundation
import HexCore

actor MCPStdioJSONRPCConnection: MCPJSONRPCConnection {
  let configuration: MCPServerConfiguration
  var state = MCPConnectionState.disconnected
  var generation = UInt64(0)
  var process: MCPSpawnedProcess?
  var pendingRequests: [Int64: MCPPendingRequest] = [:]
  var nextRequestID = Int64(1)
  var outputBuffer = Data()
  var retainedErrorOutput = Data()
  var readerTasks: [Task<Void, Never>] = []
  var writeQueue: [MCPWriteOperation] = []
  var activeWriterGeneration: UInt64?

  init(configuration: MCPServerConfiguration) {
    self.configuration = configuration
  }

  func connect() async throws {
    try Task.checkCancellation()
    guard case .disconnected = state else {
      throw MCPClientSessionError.alreadyConnected
    }
    guard generation < UInt64.max else {
      throw MCPClientSessionError.limitExceeded
    }
    let spawned = try MCPStdioProcessSpawner.spawn(configuration)
    generation += 1
    let connectedGeneration = generation
    process = spawned
    outputBuffer = Data()
    retainedErrorOutput = Data()
    nextRequestID = 1
    state = .connected
    readerTasks = [
      Self.readerTask(
        descriptor: spawned.outputDescriptor,
        channel: .output,
        generation: connectedGeneration,
        connection: self
      ),
      Self.readerTask(
        descriptor: spawned.errorDescriptor,
        channel: .error,
        generation: connectedGeneration,
        connection: self
      ),
    ]
  }

  func request(method: String, params: JSONValue) async throws -> JSONValue {
    try Task.checkCancellation()
    guard case .connected = state, pendingRequests.count < 64 else {
      throw MCPClientSessionError.connectionClosed
    }
    guard Self.validMethod(method), nextRequestID < Int64.max else {
      throw MCPClientSessionError.protocolViolation
    }
    let requestID = nextRequestID
    let requestGeneration = generation
    nextRequestID += 1
    let data = try encodedMessage(
      .object([
        "jsonrpc": .string("2.0"),
        "id": .integer(requestID),
        "method": .string(method),
        "params": params,
      ])
    )

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let timeoutTask = Task { [weak self] in
          try? await Task.sleep(
            for: .milliseconds(Int64(self?.configuration.requestTimeoutMilliseconds ?? 1))
          )
          guard !Task.isCancelled else { return }
          await self?.requestTimedOut(requestID, generation: requestGeneration)
        }
        pendingRequests[requestID] = MCPPendingRequest(
          continuation: continuation,
          timeoutTask: timeoutTask
        )
        Task { [weak self] in
          await self?.sendRegisteredRequest(
            data,
            requestID: requestID,
            generation: requestGeneration
          )
        }
        if Task.isCancelled {
          Task { [weak self] in
            await self?.cancelRequest(requestID, generation: requestGeneration)
          }
        }
      }
    } onCancel: {
      Task { [weak self] in
        await self?.cancelRequest(requestID, generation: requestGeneration)
      }
    }
  }

  func notify(method: String, params: JSONValue?) async throws {
    try Task.checkCancellation()
    guard case .connected = state, Self.validMethod(method) else {
      throw MCPClientSessionError.connectionClosed
    }
    var object: [String: JSONValue] = [
      "jsonrpc": .string("2.0"),
      "method": .string(method),
    ]
    if let params { object["params"] = params }
    try await enqueueWrite(try encodedMessage(.object(object)), generation: generation)
  }

  func disconnect() async {
    guard case .disconnected = state else {
      await closeConnection(error: MCPClientSessionError.connectionClosed)
      return
    }
  }

  func encodedMessage(_ value: JSONValue) throws -> Data {
    guard
      MCPJSONValueValidator.isValid(
        value,
        maximumStringBytes: configuration.maximumMessageBytes,
        maximumEstimatedBytes: configuration.maximumMessageBytes
      )
    else {
      throw MCPClientSessionError.limitExceeded
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(value)
    guard data.count <= configuration.maximumMessageBytes else {
      throw MCPClientSessionError.limitExceeded
    }
    data.append(0x0A)
    return data
  }

  static func validMethod(_ value: String) -> Bool {
    !value.isEmpty
      && value.utf8.count <= 128
      && !value.contains("\0")
      && value.utf8.allSatisfy { byte in
        (48...57).contains(byte)
          || (65...90).contains(byte)
          || (97...122).contains(byte)
          || byte == 45
          || byte == 46
          || byte == 47
          || byte == 95
      }
  }
}
