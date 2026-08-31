import Foundation
import HexCore

extension MCPStdioJSONRPCConnection {
  func received(
    _ data: Data,
    from channel: MCPReadChannel,
    generation: UInt64
  ) async {
    guard generation == self.generation, case .connected = state else { return }
    switch channel {
    case .error:
      retainErrorOutput(data)
    case .output:
      do {
        try await receiveOutput(data)
      } catch {
        await closeConnection(error: error)
      }
    }
  }

  func readerEnded(_ channel: MCPReadChannel, generation: UInt64) async {
    guard generation == self.generation, case .connected = state else { return }
    if case .output = channel {
      await closeConnection(error: MCPClientSessionError.connectionClosed)
    }
  }

  func readerFailed(_ channel: MCPReadChannel, generation: UInt64) async {
    guard generation == self.generation, case .connected = state else { return }
    _ = channel
    await closeConnection(error: MCPClientSessionError.connectionClosed)
  }

  func requestTimedOut(_ requestID: Int64, generation: UInt64) async {
    guard generation == self.generation else { return }
    guard let pending = pendingRequests.removeValue(forKey: requestID) else { return }
    pending.timeoutTask.cancel()
    pending.continuation.resume(throwing: MCPClientSessionError.requestTimedOut)
    await closeConnection(error: MCPClientSessionError.connectionClosed)
  }

  func cancelRequest(_ requestID: Int64, generation: UInt64) async {
    guard generation == self.generation else { return }
    guard let pending = pendingRequests.removeValue(forKey: requestID) else { return }
    pending.timeoutTask.cancel()
    pending.continuation.resume(throwing: CancellationError())
    await closeConnection(error: MCPClientSessionError.connectionClosed)
  }

  private func receiveOutput(_ data: Data) async throws {
    outputBuffer.append(data)
    while let newline = outputBuffer.firstIndex(of: 0x0A) {
      var line = Data(outputBuffer[..<newline])
      outputBuffer.removeSubrange(...newline)
      if line.last == 0x0D { line.removeLast() }
      guard !line.isEmpty else {
        throw MCPClientSessionError.protocolViolation
      }
      guard line.count <= configuration.maximumMessageBytes else {
        throw MCPClientSessionError.limitExceeded
      }
      try MCPJSONStructuralPreflight.validateObjectRoot(line)
      let value: JSONValue
      do {
        value = try JSONDecoder().decode(JSONValue.self, from: line)
      } catch {
        throw MCPClientSessionError.protocolViolation
      }
      try await handleMessage(value)
    }
    guard outputBuffer.count <= configuration.maximumMessageBytes else {
      throw MCPClientSessionError.limitExceeded
    }
  }

  private func handleMessage(_ value: JSONValue) async throws {
    guard
      let object = value.mcpObject,
      object["jsonrpc"] == .string("2.0")
    else {
      throw MCPClientSessionError.protocolViolation
    }
    if let method = object["method"]?.mcpString {
      guard
        Self.validMethod(method),
        object["result"] == nil,
        object["error"] == nil,
        object["params"] == nil || object["params"]?.mcpObject != nil
      else {
        throw MCPClientSessionError.protocolViolation
      }
      if let requestID = object["id"] {
        guard validServerRequestID(requestID) else {
          throw MCPClientSessionError.protocolViolation
        }
        if method == "ping" {
          try await sendResult(id: requestID, result: .object([:]))
        } else {
          try await sendMethodNotFound(id: requestID, method: method)
        }
      }
      return
    }

    guard
      let requestID = object["id"]?.mcpInteger,
      requestID > 0,
      let pending = pendingRequests.removeValue(forKey: requestID)
    else {
      throw MCPClientSessionError.protocolViolation
    }
    pending.timeoutTask.cancel()
    let hasResult = object["result"] != nil
    let hasError = object["error"] != nil
    guard hasResult != hasError else {
      pending.continuation.resume(throwing: MCPClientSessionError.protocolViolation)
      throw MCPClientSessionError.protocolViolation
    }
    if let result = object["result"] {
      pending.continuation.resume(returning: result)
      return
    }
    guard
      let errorObject = object["error"]?.mcpObject,
      let code = errorObject["code"]?.mcpInteger,
      let message = errorObject["message"]?.mcpString,
      !message.isEmpty,
      message.utf8.count <= 8_192
    else {
      pending.continuation.resume(throwing: MCPClientSessionError.protocolViolation)
      throw MCPClientSessionError.protocolViolation
    }
    pending.continuation.resume(throwing: MCPClientSessionError.remoteError(code: code))
  }

  private func sendResult(id: JSONValue, result: JSONValue) async throws {
    try await enqueueWrite(
      try encodedMessage(
        .object([
          "jsonrpc": .string("2.0"),
          "id": id,
          "result": result,
        ])
      ),
      generation: generation
    )
  }

  private func sendMethodNotFound(id: JSONValue, method: String) async throws {
    guard method.utf8.count <= 128, !method.contains("\0") else {
      throw MCPClientSessionError.protocolViolation
    }
    try await enqueueWrite(
      try encodedMessage(
        .object([
          "jsonrpc": .string("2.0"),
          "id": id,
          "error": .object([
            "code": .integer(-32_601),
            "message": .string("Method not supported by this client."),
          ]),
        ])
      ),
      generation: generation
    )
  }

  private func validServerRequestID(_ value: JSONValue) -> Bool {
    switch value {
    case .integer(let id):
      return id >= 0
    case .string(let id):
      return !id.isEmpty && id.utf8.count <= 128 && !id.contains("\0")
    default:
      return false
    }
  }

  private func retainErrorOutput(_ data: Data) {
    let maximum = configuration.maximumStderrBytes
    guard maximum > 0 else { return }
    if data.count >= maximum {
      retainedErrorOutput = Data(data.suffix(maximum))
      return
    }
    retainedErrorOutput.append(data)
    if retainedErrorOutput.count > maximum {
      retainedErrorOutput.removeFirst(retainedErrorOutput.count - maximum)
    }
  }
}
