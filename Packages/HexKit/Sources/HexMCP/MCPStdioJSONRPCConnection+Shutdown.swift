import Darwin
import Dispatch
import Foundation

extension MCPStdioJSONRPCConnection {
  func closeConnection(error: any Error) async {
    guard case .disconnected = state else {
      state = .closing
      let pending = pendingRequests
      pendingRequests = [:]
      for request in pending.values {
        request.timeoutTask.cancel()
        request.continuation.resume(throwing: error)
      }
      failQueuedWrites(with: error)
      let spawned = process
      process = nil
      let tasks = readerTasks
      readerTasks = []
      for task in tasks {
        task.cancel()
      }
      if let spawned {
        await terminate(spawned)
      }
      outputBuffer = Data()
      retainedErrorOutput = Data()
      activeWriterGeneration = nil
      state = .disconnected
      return
    }
  }

  private func terminate(_ spawned: MCPSpawnedProcess) async {
    Darwin.close(spawned.inputDescriptor)
    if Darwin.kill(-spawned.processID, SIGTERM) != 0 {
      _ = Darwin.kill(spawned.processID, SIGTERM)
    }
    var reaped = false
    let start = DispatchTime.now().uptimeNanoseconds
    let graceNanoseconds = configuration.shutdownGraceMilliseconds * 1_000_000
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
