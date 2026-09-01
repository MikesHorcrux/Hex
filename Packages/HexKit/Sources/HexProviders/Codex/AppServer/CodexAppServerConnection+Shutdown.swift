import Foundation

extension CodexAppServerConnection {
  func closeConnection(error: any Error) async {
    guard let shutdown = beginShutdown(error: error) else { return }
    await shutdown.completion.value
  }

  func beginShutdown(error: any Error) -> CodexAppServerConnectionShutdown? {
    if let shutdown {
      return shutdown
    }
    guard state != .disconnected, state != .retired else {
      return nil
    }

    let shutdownID = UUID()
    let shutdownGeneration = generation
    state = .closing
    let pending = pendingRequests
    pendingRequests = [:]
    for request in pending.values {
      request.timeoutTask.cancel()
    }
    readerTask?.cancel()
    readerTask = nil
    let channel = self.channel
    let completion = Task { [weak self] in
      await channel.close()
      await self?.finishShutdown(id: shutdownID, generation: shutdownGeneration)
      for request in pending.values {
        request.continuation.resume(throwing: error)
      }
    }
    let created = CodexAppServerConnectionShutdown(
      id: shutdownID,
      generation: shutdownGeneration,
      completion: completion
    )
    shutdown = created
    return created
  }

  func finishShutdown(id: UUID, generation shutdownGeneration: UInt64) {
    guard generation == shutdownGeneration,
      shutdown?.id == id,
      shutdown?.generation == shutdownGeneration,
      state == .closing
    else {
      return
    }
    outputBuffer = Data()
    if establishmentGeneration == shutdownGeneration {
      state = .closing
    } else {
      state = .disconnected
      shutdown = nil
    }
  }
}
