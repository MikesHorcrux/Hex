import Darwin
import Foundation

extension MCPStdioJSONRPCConnection {
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

  func enqueueWrite(_ data: Data, generation: UInt64) async throws {
    guard generation == self.generation, case .connected = state else {
      throw MCPClientSessionError.connectionClosed
    }
    try await withCheckedThrowingContinuation { continuation in
      writeQueue.append(
        MCPWriteOperation(
          generation: generation,
          data: data,
          continuation: continuation
        )
      )
      guard activeWriterGeneration == nil else { return }
      activeWriterGeneration = generation
      Task { [weak self] in
        await self?.drainWrites(generation: generation)
      }
    }
  }

  func drainWrites(generation: UInt64) async {
    while !writeQueue.isEmpty {
      guard
        generation == self.generation,
        activeWriterGeneration == generation,
        case .connected = state,
        let descriptor = process?.inputDescriptor
      else {
        failQueuedWrites(
          with: MCPClientSessionError.connectionClosed,
          generation: generation
        )
        if activeWriterGeneration == generation { activeWriterGeneration = nil }
        return
      }
      guard writeQueue[0].generation == generation else {
        if activeWriterGeneration == generation { activeWriterGeneration = nil }
        return
      }
      let operation = writeQueue.removeFirst()
      var offset = 0
      do {
        while offset < operation.data.count {
          guard
            generation == self.generation,
            activeWriterGeneration == generation,
            case .connected = state
          else {
            throw MCPClientSessionError.connectionClosed
          }
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
            try await Task.sleep(for: .milliseconds(5))
          } else {
            throw MCPClientSessionError.connectionClosed
          }
        }
        operation.continuation.resume()
      } catch {
        operation.continuation.resume(throwing: error)
        failQueuedWrites(with: error, generation: generation)
        if activeWriterGeneration == generation { activeWriterGeneration = nil }
        if generation == self.generation {
          await closeConnection(error: error)
        }
        return
      }
    }
    if activeWriterGeneration == generation { activeWriterGeneration = nil }
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

  func failQueuedWrites(with error: any Error, generation: UInt64) {
    let queued = writeQueue
    writeQueue = queued.filter { $0.generation != generation }
    for operation in queued where operation.generation == generation {
      operation.continuation.resume(throwing: error)
    }
  }
}
