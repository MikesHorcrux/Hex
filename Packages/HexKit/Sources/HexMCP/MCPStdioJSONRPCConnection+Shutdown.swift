import Darwin
import Dispatch
import Foundation

extension MCPStdioJSONRPCConnection {
  func closeConnection(error: any Error) async {
    guard let shutdown = beginShutdown(error: error) else { return }
    await shutdown.completion.value
  }

  func beginShutdown(error: any Error) -> MCPConnectionShutdown? {
    if let shutdown { return shutdown }
    guard case .disconnected = state else {
      let shutdownID = UUID()
      let shutdownGeneration = generation
      state = .closing
      let pending = pendingRequests
      pendingRequests = [:]
      for request in pending.values {
        request.timeoutTask.cancel()
        request.continuation.resume(throwing: error)
      }
      failQueuedWrites(with: error, generation: shutdownGeneration)
      let spawned = process
      process = nil
      let tasks = readerTasks
      readerTasks = []
      for task in tasks {
        task.cancel()
      }
      let terminateProcess = self.terminateProcess
      let completion = Task { [weak self] in
        if let spawned {
          await terminateProcess(spawned)
        }
        await self?.finishShutdown(
          id: shutdownID,
          generation: shutdownGeneration
        )
      }
      let createdShutdown = MCPConnectionShutdown(
        id: shutdownID,
        generation: shutdownGeneration,
        completion: completion
      )
      shutdown = createdShutdown
      return createdShutdown
    }
    return nil
  }

  func finishShutdown(id: UUID, generation: UInt64) {
    guard
      self.generation == generation,
      shutdown?.id == id,
      shutdown?.generation == generation,
      case .closing = state
    else {
      return
    }
    outputBuffer = Data()
    retainedErrorOutput = Data()
    activeWriterGeneration = nil
    state = .disconnected
    shutdown = nil
  }

  static func terminate(
    _ spawned: MCPSpawnedProcess,
    shutdownGraceMilliseconds: UInt64
  ) async {
    Darwin.close(spawned.inputDescriptor)
    if Darwin.kill(-spawned.processID, SIGTERM) != 0 {
      _ = Darwin.kill(spawned.processID, SIGTERM)
    }
    var reaped = false
    let start = DispatchTime.now().uptimeNanoseconds
    let graceNanoseconds = shutdownGraceMilliseconds * 1_000_000
    let (deadline, overflowed) = start.addingReportingOverflow(graceNanoseconds)

    if !overflowed {
      while DispatchTime.now().uptimeNanoseconds < deadline {
        if !reaped {
          var status = Int32(0)
          let result = waitpid(spawned.processID, &status, WNOHANG)
          if result == spawned.processID { reaped = true }
        }
        let groupExists = Darwin.kill(-spawned.processID, 0) == 0 || errno == EPERM
        if reaped && !groupExists { break }
        try? await Task.sleep(for: .milliseconds(10))
      }
    }
    if Darwin.kill(-spawned.processID, SIGKILL) != 0 {
      _ = Darwin.kill(spawned.processID, SIGKILL)
    }
    if !reaped {
      var status = Int32(0)
      while waitpid(spawned.processID, &status, 0) < 0, errno == EINTR {}
    }
    Darwin.close(spawned.outputDescriptor)
    Darwin.close(spawned.errorDescriptor)
  }
}
