import Foundation
import HexCore

extension CodexAppServerConnection {
  func received(_ data: Data, generation messageGeneration: UInt64) async {
    guard generation == messageGeneration,
      state == .handshaking || state == .ready
    else {
      return
    }
    do {
      try await receiveOutput(data, generation: messageGeneration)
    } catch {
      await closeConnection(error: sanitized(error))
    }
  }

  func readerEnded(generation readerGeneration: UInt64) async {
    guard generation == readerGeneration,
      state == .handshaking || state == .ready
    else {
      return
    }
    await closeConnection(error: CodexAppServerConnectionError.connectionClosed)
  }

  func readerFailed(generation readerGeneration: UInt64) async {
    guard generation == readerGeneration,
      state == .handshaking || state == .ready
    else {
      return
    }
    await closeConnection(error: CodexAppServerConnectionError.transportFailure)
  }

  private func receiveOutput(_ data: Data, generation messageGeneration: UInt64) async throws {
    var cursor = data.startIndex
    while cursor < data.endIndex,
      let newline = data[cursor...].firstIndex(of: 0x0A)
    {
      try appendOutput(data[cursor..<newline])
      try await consumeOutputLine(generation: messageGeneration)
      cursor = data.index(after: newline)
    }
    if cursor < data.endIndex {
      try appendOutput(data[cursor...])
    }
  }

  private func appendOutput(_ bytes: Data.SubSequence) throws {
    let (combinedCount, overflowed) = outputBuffer.count.addingReportingOverflow(bytes.count)
    guard !overflowed, combinedCount <= configuration.maximumMessageBytes else {
      throw CodexAppServerConnectionError.limitExceeded
    }
    outputBuffer.append(contentsOf: bytes)
  }

  private func consumeOutputLine(generation messageGeneration: UInt64) async throws {
    var line = outputBuffer
    outputBuffer.removeAll(keepingCapacity: true)
    if line.last == 0x0D {
      line.removeLast()
    }
    guard !line.isEmpty else {
      throw CodexAppServerConnectionError.protocolViolation
    }
    try CodexAppServerJSONStructuralPreflight.validateObjectRoot(line)
    let value: JSONValue
    do {
      value = try JSONDecoder().decode(JSONValue.self, from: line)
    } catch {
      throw CodexAppServerConnectionError.protocolViolation
    }
    try await handleMessage(value, generation: messageGeneration)
  }

  private func handleMessage(_ value: JSONValue, generation messageGeneration: UInt64) async throws
  {
    guard generation == messageGeneration, case .object(let object) = value else {
      throw CodexAppServerConnectionError.connectionClosed
    }
    guard object["jsonrpc"] == nil else {
      throw CodexAppServerConnectionError.protocolViolation
    }

    if case .string(let method)? = object["method"] {
      guard Self.validMethod(method), object["result"] == nil, object["error"] == nil else {
        throw CodexAppServerConnectionError.protocolViolation
      }
      if let requestID = object["id"] {
        guard state == .ready, validServerRequestID(requestID) else {
          throw CodexAppServerConnectionError.protocolViolation
        }
        try await sendMethodNotFound(id: requestID, generation: messageGeneration)
      } else {
        guard state == .ready else {
          throw CodexAppServerConnectionError.protocolViolation
        }
        if let notificationHandler {
          try await notificationHandler.handle(
            CodexAppServerNotification(method: method, parameters: object["params"])
          )
        }
      }
      return
    }

    guard case .integer(let requestID)? = object["id"], requestID > 0,
      let pending = pendingRequests.removeValue(forKey: requestID)
    else {
      throw CodexAppServerConnectionError.protocolViolation
    }
    pending.timeoutTask.cancel()
    let hasResult = object["result"] != nil
    let hasError = object["error"] != nil
    guard hasResult != hasError else {
      pending.continuation.resume(throwing: CodexAppServerConnectionError.protocolViolation)
      throw CodexAppServerConnectionError.protocolViolation
    }
    if let result = object["result"] {
      pending.continuation.resume(returning: result)
      return
    }
    guard case .object(let errorObject)? = object["error"],
      case .integer(let code)? = errorObject["code"],
      case .string(let message)? = errorObject["message"],
      !message.isEmpty,
      message.utf8.count <= 8_192
    else {
      pending.continuation.resume(throwing: CodexAppServerConnectionError.protocolViolation)
      throw CodexAppServerConnectionError.protocolViolation
    }
    pending.continuation.resume(throwing: CodexAppServerConnectionError.remoteError(code: code))
  }

  private func sendMethodNotFound(id: JSONValue, generation messageGeneration: UInt64) async throws
  {
    let frame = try encodedFrame(
      .object([
        "id": id,
        "error": .object([
          "code": .integer(-32_601),
          "message": .string("Method not supported by this client."),
        ]),
      ])
    )
    do {
      try await channel.write(frame)
    } catch {
      throw sanitized(error)
    }
    guard generation == messageGeneration, state == .ready else {
      throw CodexAppServerConnectionError.connectionClosed
    }
  }

  private func validServerRequestID(_ value: JSONValue) -> Bool {
    switch value {
    case .integer(let identifier):
      identifier >= 0
    case .string(let identifier):
      !identifier.isEmpty && identifier.utf8.count <= 128
        && !identifier.unicodeScalars.contains { scalar in
          switch scalar.properties.generalCategory {
          case .control, .format, .lineSeparator, .paragraphSeparator:
            true
          default:
            false
          }
        }
    default:
      false
    }
  }
}
