import Foundation
import HexCore

extension CodexAppServerConnection {
  func requestResult(
    method: String,
    parameters: JSONValue,
    generation requestGeneration: UInt64,
    permittedState: CodexAppServerConnectionState
  ) async throws -> JSONValue {
    try Task.checkCancellation()
    guard generation == requestGeneration, state == permittedState else {
      throw CodexAppServerConnectionError.connectionClosed
    }
    guard Self.validMethod(method) else {
      throw CodexAppServerConnectionError.protocolViolation
    }
    guard pendingRequests.count < configuration.maximumPendingRequests,
      nextRequestID < Int64.max
    else {
      throw CodexAppServerConnectionError.limitExceeded
    }

    let requestID = nextRequestID
    nextRequestID += 1
    let frame: Data
    do {
      frame = try encodedFrame(
        .object([
          "id": .integer(requestID),
          "method": .string(method),
          "params": parameters,
        ])
      )
    } catch {
      throw sanitized(error)
    }

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let timeoutMilliseconds = configuration.requestTimeoutMilliseconds
        let timeoutTask = Task { [weak self] in
          try? await Task.sleep(for: .milliseconds(Int64(timeoutMilliseconds)))
          guard !Task.isCancelled else { return }
          await self?.requestTimedOut(requestID, generation: requestGeneration)
        }
        pendingRequests[requestID] = CodexAppServerPendingRequest(
          continuation: continuation,
          timeoutTask: timeoutTask,
          response: nil
        )
        Task { [weak self] in
          await self?.writeRegisteredRequest(
            frame,
            requestID: requestID,
            generation: requestGeneration,
            permittedState: permittedState
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

  func writeRegisteredRequest(
    _ frame: Data,
    requestID: Int64,
    generation requestGeneration: UInt64,
    permittedState: CodexAppServerConnectionState
  ) async {
    do {
      guard generation == requestGeneration, state == permittedState else {
        throw CodexAppServerConnectionError.connectionClosed
      }
      try await channel.write(frame)
      guard generation == requestGeneration, state == permittedState,
        var pending = pendingRequests[requestID]
      else {
        return
      }
      if let response = pending.response {
        pendingRequests.removeValue(forKey: requestID)
        pending.timeoutTask.cancel()
        pending.resume(with: response)
      } else {
        pending.writeCompleted = true
        pendingRequests[requestID] = pending
      }
    } catch {
      guard generation == requestGeneration else { return }
      guard state == permittedState || state == .closing else { return }
      await closeConnection(error: sanitized(error))
    }
  }

  func writeNotification(
    method: String,
    parameters: JSONValue?,
    generation notificationGeneration: UInt64,
    permittedState: CodexAppServerConnectionState
  ) async throws {
    guard generation == notificationGeneration, state == permittedState else {
      throw CodexAppServerConnectionError.connectionClosed
    }
    guard Self.validMethod(method) else {
      throw CodexAppServerConnectionError.protocolViolation
    }
    var object: [String: JSONValue] = ["method": .string(method)]
    if let parameters {
      object["params"] = parameters
    }
    do {
      try await channel.write(try encodedFrame(.object(object)))
    } catch {
      throw sanitized(error)
    }
  }

  func requestTimedOut(_ requestID: Int64, generation requestGeneration: UInt64) async {
    guard generation == requestGeneration else { return }
    guard let pending = pendingRequests.removeValue(forKey: requestID) else { return }
    pending.timeoutTask.cancel()
    if let shutdown = beginShutdown(error: CodexAppServerConnectionError.connectionClosed) {
      await shutdown.completion.value
    }
    pending.continuation.resume(throwing: CodexAppServerConnectionError.requestTimedOut)
  }

  func cancelRequest(_ requestID: Int64, generation requestGeneration: UInt64) async {
    guard generation == requestGeneration else { return }
    guard let pending = pendingRequests.removeValue(forKey: requestID) else { return }
    pending.timeoutTask.cancel()
    if let shutdown = beginShutdown(error: CodexAppServerConnectionError.connectionClosed) {
      await shutdown.completion.value
    }
    pending.continuation.resume(throwing: CancellationError())
  }
}
