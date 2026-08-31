import Darwin
import Dispatch
import Foundation

extension MCPStdioJSONRPCConnection {
  private static let writeRetryNanoseconds: UInt64 = 5_000_000

  static func readerTask(
    descriptor: Int32,
    channel: MCPReadChannel,
    generation: UInt64,
    connection: MCPStdioJSONRPCConnection
  ) -> Task<Void, Never> {
    let readerDescriptor = Darwin.dup(descriptor)
    guard readerDescriptor >= 0 else {
      return Task { await connection.readerFailed(channel, generation: generation) }
    }
    let descriptorFlags = fcntl(readerDescriptor, F_GETFD)
    if descriptorFlags >= 0 {
      _ = fcntl(readerDescriptor, F_SETFD, descriptorFlags | FD_CLOEXEC)
    }
    return Task.detached { [weak connection] in
      defer { Darwin.close(readerDescriptor) }
      var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
      while !Task.isCancelled {
        let count = buffer.withUnsafeMutableBytes { bytes in
          Darwin.read(readerDescriptor, bytes.baseAddress, bytes.count)
        }
        if count > 0 {
          await connection?.received(
            Data(buffer[..<count]),
            from: channel,
            generation: generation
          )
          continue
        }
        if count == 0 {
          await connection?.readerEnded(channel, generation: generation)
          return
        }
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK {
          try? await Task.sleep(for: .milliseconds(5))
          continue
        }
        await connection?.readerFailed(channel, generation: generation)
        return
      }
    }
  }

  func enqueueWrite(
    _ data: Data,
    generation: UInt64,
    operationID: UUID = UUID()
  ) async throws {
    try Task.checkCancellation()
    guard
      generation == self.generation,
      case .connected = state,
      !data.isEmpty,
      data.count <= configuration.maximumMessageBytes + 1
    else {
      throw MCPClientSessionError.connectionClosed
    }
    let deadline = writeDeadlineUptimeNanoseconds()
    try await withCheckedThrowingContinuation { continuation in
      guard !Task.isCancelled else {
        continuation.resume(throwing: CancellationError())
        return
      }
      guard
        generation == self.generation,
        case .connected = state
      else {
        continuation.resume(throwing: MCPClientSessionError.connectionClosed)
        return
      }
      guard writeQueue.count < Self.maximumQueuedWriteOperations else {
        continuation.resume(throwing: MCPClientSessionError.limitExceeded)
        return
      }
      let (nextByteCount, overflowed) = queuedWriteByteCount.addingReportingOverflow(data.count)
      guard
        !overflowed,
        nextByteCount <= configuration.maximumMessageBytes + 1
      else {
        continuation.resume(throwing: MCPClientSessionError.limitExceeded)
        return
      }
      writeQueue.append(
        MCPWriteOperation(
          id: operationID,
          generation: generation,
          data: data,
          deadlineUptimeNanoseconds: deadline,
          continuation: continuation
        )
      )
      queuedWriteByteCount = nextByteCount
      guard activeWriterGeneration == nil else { return }
      startWriterIfNeeded()
    }
  }

  func enqueueCancellableWrite(
    _ data: Data,
    generation: UInt64,
    operationID: UUID = UUID()
  ) async throws {
    try await withTaskCancellationHandler {
      try await enqueueWrite(
        data,
        generation: generation,
        operationID: operationID
      )
    } onCancel: {
      Task { [weak self] in
        await self?.cancelWrite(operationID: operationID, generation: generation)
      }
    }
  }

  func drainWrites(generation: UInt64) async {
    while true {
      guard
        generation == self.generation,
        activeWriterGeneration == generation,
        case .connected = state,
        let descriptor = process?.inputDescriptor
      else {
        failActiveWrite(
          with: MCPClientSessionError.connectionClosed,
          generation: generation
        )
        failQueuedWrites(
          with: MCPClientSessionError.connectionClosed,
          generation: generation
        )
        if activeWriterGeneration == generation {
          activeWriterGeneration = nil
          startWriterIfNeeded()
        }
        return
      }
      guard let queuedOperation = writeQueue.first else {
        if activeWriterGeneration == generation { activeWriterGeneration = nil }
        return
      }
      guard queuedOperation.generation == generation else {
        // A replacement generation owns this queue. The old writer may finish
        // without consuming or failing any of the replacement's operations.
        failActiveWrite(
          with: MCPClientSessionError.connectionClosed,
          generation: generation
        )
        if activeWriterGeneration == generation {
          activeWriterGeneration = nil
          startWriterIfNeeded()
        }
        return
      }
      let operation = writeQueue.removeFirst()
      queuedWriteByteCount -= operation.data.count
      activeWriteOperations[generation] = operation
      var offset = 0
      do {
        while offset < operation.data.count {
          guard isActiveWrite(operation, generation: generation) else { return }
          guard
            generation == self.generation,
            activeWriterGeneration == generation,
            case .connected = state
          else {
            throw MCPClientSessionError.connectionClosed
          }
          try checkWriteDeadline(operation)
          let written = operation.data.withUnsafeBytes { bytes -> Int in
            guard let baseAddress = bytes.baseAddress else { return -1 }
            return Darwin.write(
              descriptor,
              baseAddress.advanced(by: offset),
              bytes.count - offset
            )
          }
          if written > 0 {
            offset += written
          } else if written < 0, errno == EINTR {
            continue
          } else if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
            try await sleepUntilWriteDeadline(operation.deadlineUptimeNanoseconds)
          } else {
            throw MCPClientSessionError.connectionClosed
          }
        }
        guard isActiveWrite(operation, generation: generation) else { return }
        activeWriteOperations.removeValue(forKey: generation)
        operation.continuation.resume()
      } catch {
        guard isActiveWrite(operation, generation: generation) else { return }
        activeWriteOperations.removeValue(forKey: generation)
        operation.continuation.resume(throwing: error)
        failQueuedWrites(with: error, generation: generation)
        if activeWriterGeneration == generation { activeWriterGeneration = nil }
        if generation == self.generation {
          await closeConnection(error: error)
        }
        return
      }
    }
  }

  func cancelWrite(operationID: UUID, generation: UInt64) async {
    guard generation == self.generation else { return }
    if let index = writeQueue.firstIndex(where: {
      $0.id == operationID && $0.generation == generation
    }) {
      let operation = writeQueue.remove(at: index)
      queuedWriteByteCount -= operation.data.count
      operation.continuation.resume(throwing: CancellationError())
      return
    }
    guard activeWriteOperations[generation]?.id == operationID else { return }
    // A partial write cannot be rolled back. Fail this continuation now and
    // close the generation so no later frame can be concatenated to it.
    failActiveWrite(with: CancellationError(), generation: generation)
    await closeConnection(error: MCPClientSessionError.connectionClosed)
  }

  func sendRegisteredRequest(
    _ data: Data,
    requestID: Int64,
    generation: UInt64
  ) async {
    do {
      try await enqueueWrite(data, generation: generation)
    } catch {
      guard generation == self.generation else { return }
      guard let pending = pendingRequests.removeValue(forKey: requestID) else { return }
      pending.timeoutTask.cancel()
      pending.continuation.resume(throwing: error)
    }
  }

  func failActiveWrite(with error: any Error, generation: UInt64) {
    guard let operation = activeWriteOperations.removeValue(forKey: generation) else {
      return
    }
    operation.continuation.resume(throwing: error)
  }

  func failQueuedWrites(with error: any Error, generation: UInt64) {
    var retained: [MCPWriteOperation] = []
    var failed: [MCPWriteOperation] = []
    var failedByteCount = 0
    retained.reserveCapacity(writeQueue.count)
    for operation in writeQueue {
      if operation.generation == generation {
        failed.append(operation)
        failedByteCount += operation.data.count
      } else {
        retained.append(operation)
      }
    }
    writeQueue = retained
    queuedWriteByteCount -= failedByteCount
    for operation in failed {
      operation.continuation.resume(throwing: error)
    }
  }

  private func startWriterIfNeeded() {
    guard case .connected = state,
      activeWriterGeneration == nil,
      let queuedGeneration = writeQueue.first?.generation
    else {
      return
    }
    activeWriterGeneration = queuedGeneration
    Task.detached { [weak self] in
      await self?.drainWrites(generation: queuedGeneration)
    }
  }

  private func isActiveWrite(_ operation: MCPWriteOperation, generation: UInt64) -> Bool {
    activeWriteOperations[generation]?.id == operation.id
  }

  private func writeDeadlineUptimeNanoseconds() -> UInt64 {
    let (duration, durationOverflowed) = configuration.requestTimeoutMilliseconds
      .multipliedReportingOverflow(by: 1_000_000)
    let timeout = durationOverflowed ? UInt64.max : duration
    let now = DispatchTime.now().uptimeNanoseconds
    let (deadline, deadlineOverflowed) = now.addingReportingOverflow(timeout)
    return deadlineOverflowed ? UInt64.max : deadline
  }

  private func checkWriteDeadline(_ operation: MCPWriteOperation) throws {
    guard DispatchTime.now().uptimeNanoseconds < operation.deadlineUptimeNanoseconds else {
      throw MCPClientSessionError.requestTimedOut
    }
  }

  private func sleepUntilWriteDeadline(_ deadline: UInt64) async throws {
    let now = DispatchTime.now().uptimeNanoseconds
    guard now < deadline else {
      throw MCPClientSessionError.requestTimedOut
    }
    let remaining = deadline - now
    try await Task.sleep(nanoseconds: min(remaining, Self.writeRetryNanoseconds))
  }
}
