import Darwin
import Foundation
import HexCore

/// Actor owns the only writer. The manager pulls bounded output; no unbounded callback queue.
actor ProcessSupervisorConnection {
  let process: Process
  let input: FileHandle
  let output: FileHandle
  var buffered = Data()
  var closed = false

  init(executable: URL, request: ProcessSupervisorRequest) throws {
    let process = Process()
    let inputPipe = Pipe()
    let outputPipe = Pipe()
    process.executableURL = executable
    process.arguments = ["--hex-process-supervisor"]
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = FileHandle.nullDevice
    process.environment = [:]
    try process.run()
    self.process = process
    input = inputPipe.fileHandleForWriting
    output = outputPipe.fileHandleForReading
    try inputPipe.fileHandleForReading.close()
    try outputPipe.fileHandleForWriting.close()
    _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
    _ = fcntl(input.fileDescriptor, F_SETFL, fcntl(input.fileDescriptor, F_GETFL) | O_NONBLOCK)
    var configuration = try JSONEncoder().encode(request)
    configuration.append(10)
    do { try Self.write(configuration, to: input.fileDescriptor) } catch {
      try? input.close()
      throw error
    }
  }

  func send(_ message: ProcessSupervisorMessage) throws {
    guard !closed else { throw ProcessSessionError.unavailable }
    var data = try JSONEncoder().encode(message)
    data.append(10)
    do { try Self.write(data, to: input.fileDescriptor) } catch {
      disconnect()
      throw error
    }
  }

  func receive() async throws -> ProcessSupervisorMessage? {
    while !buffered.contains(10) {
      let handle = output
      let chunk = try await Task.detached {
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
          // Foundation's read(upToCount:) can wait to fill the requested buffer. A single POSIX
          // read returns currently available bytes so a REPL prompt arrives before process exit.
          let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
          if count >= 0 { return Data(buffer.prefix(count)) }
          if errno != EINTR { throw ProcessSessionError.outputUnavailable }
        }
      }.value
      if chunk.isEmpty { return nil }
      buffered.append(chunk)
      guard buffered.count <= 128 * 1_024 else { throw ProcessSessionError.outputUnavailable }
    }
    guard let newline = buffered.firstIndex(of: 10) else { return nil }
    let message = try JSONDecoder().decode(
      ProcessSupervisorMessage.self, from: Data(buffered[..<newline]))
    buffered.removeSubrange(...newline)
    return message
  }

  func disconnect() {
    guard !closed else { return }
    closed = true
    try? input.close()
  }

  private static func write(_ data: Data, to descriptor: Int32) throws {
    let deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 2_000_000_000
    try data.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        guard clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < deadline else {
          throw ProcessSessionError.inputUncertain
        }
        let count = Darwin.write(
          descriptor, buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
        if count > 0 {
          offset += count
        } else if errno == EAGAIN || errno == EINTR {
          usleep(1_000)
        } else {
          throw ProcessSessionError.inputUncertain
        }
      }
    }
  }
}
