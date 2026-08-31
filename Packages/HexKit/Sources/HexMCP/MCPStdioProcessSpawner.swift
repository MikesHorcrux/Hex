import Darwin
import Foundation

enum MCPStdioProcessSpawner {
  static func spawn(_ configuration: MCPServerConfiguration) throws -> MCPSpawnedProcess {
    let pipes = try makePipeSet()
    let inputPipe = pipes.input
    let outputPipe = pipes.output
    let errorPipe = pipes.error
    let executableDescriptor = moveAboveStandardDescriptors(
      Darwin.open(
        configuration.executableURL.path,
        O_RDONLY | O_NOFOLLOW | O_CLOEXEC
      )
    )
    var workingDirectoryDescriptor = Int32(-1)
    var fileActions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    var processID = pid_t(0)
    var didSpawn = false

    defer {
      Darwin.close(inputPipe.read)
      Darwin.close(outputPipe.write)
      Darwin.close(errorPipe.write)
      if !didSpawn {
        Darwin.close(inputPipe.write)
        Darwin.close(outputPipe.read)
        Darwin.close(errorPipe.read)
      }
      if executableDescriptor >= 0 { Darwin.close(executableDescriptor) }
      if workingDirectoryDescriptor >= 0 { Darwin.close(workingDirectoryDescriptor) }
      if fileActions != nil { posix_spawn_file_actions_destroy(&fileActions) }
      if attributes != nil { posix_spawnattr_destroy(&attributes) }
    }

    guard executableDescriptor >= 0 else {
      throw MCPClientSessionError.connectionClosed
    }
    var executableStatus = stat()
    guard
      fstat(executableDescriptor, &executableStatus) == 0,
      executableStatus.st_mode & S_IFMT == S_IFREG,
      access(configuration.executableURL.path, X_OK) == 0
    else {
      throw MCPClientSessionError.connectionClosed
    }

    workingDirectoryDescriptor = moveAboveStandardDescriptors(
      Darwin.open(
        configuration.workingDirectory.path,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
      )
    )
    guard workingDirectoryDescriptor >= 0 else {
      throw MCPClientSessionError.connectionClosed
    }
    guard
      setCloseOnExec(inputPipe.read),
      setCloseOnExec(inputPipe.write),
      setCloseOnExec(outputPipe.read),
      setCloseOnExec(outputPipe.write),
      setCloseOnExec(errorPipe.read),
      setCloseOnExec(errorPipe.write),
      posix_spawn_file_actions_init(&fileActions) == 0,
      posix_spawnattr_init(&attributes) == 0,
      posix_spawn_file_actions_addinherit_np(&fileActions, workingDirectoryDescriptor) == 0,
      posix_spawn_file_actions_addfchdir_np(&fileActions, workingDirectoryDescriptor) == 0,
      posix_spawn_file_actions_adddup2(&fileActions, inputPipe.read, STDIN_FILENO) == 0,
      posix_spawn_file_actions_adddup2(&fileActions, outputPipe.write, STDOUT_FILENO) == 0,
      posix_spawn_file_actions_adddup2(&fileActions, errorPipe.write, STDERR_FILENO) == 0,
      addCloseActions(
        &fileActions,
        descriptors: [
          inputPipe.read,
          inputPipe.write,
          outputPipe.read,
          outputPipe.write,
          errorPipe.read,
          errorPipe.write,
          workingDirectoryDescriptor,
        ]
      ),
      posix_spawnattr_setflags(
        &attributes,
        Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
      ) == 0,
      posix_spawnattr_setpgroup(&attributes, 0) == 0
    else {
      throw MCPClientSessionError.connectionClosed
    }

    let arguments = [configuration.executableURL.path] + configuration.arguments
    let environment = configuration.environment
      .sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value)" }
    let spawnResult = try withCStringVector(arguments) { argumentVector in
      try withCStringVector(environment) { environmentVector in
        posix_spawn(
          &processID,
          configuration.executableURL.path,
          &fileActions,
          &attributes,
          argumentVector,
          environmentVector
        )
      }
    }
    guard spawnResult == 0, processID > 0 else {
      throw MCPClientSessionError.connectionClosed
    }

    var postSpawnStatus = stat()
    guard
      lstat(configuration.executableURL.path, &postSpawnStatus) == 0,
      postSpawnStatus.st_mode & S_IFMT == S_IFREG,
      postSpawnStatus.st_dev == executableStatus.st_dev,
      postSpawnStatus.st_ino == executableStatus.st_ino,
      setNonblocking(inputPipe.write),
      setNonblocking(outputPipe.read),
      setNonblocking(errorPipe.read)
    else {
      terminateImmediately(processID)
      throw MCPClientSessionError.connectionClosed
    }

    didSpawn = true
    return MCPSpawnedProcess(
      processID: processID,
      inputDescriptor: inputPipe.write,
      outputDescriptor: outputPipe.read,
      errorDescriptor: errorPipe.read
    )
  }

  static func terminateImmediately(_ processID: pid_t) {
    guard processID > 0 else { return }
    if Darwin.kill(-processID, SIGKILL) != 0 {
      _ = Darwin.kill(processID, SIGKILL)
    }
    var status = Int32(0)
    while waitpid(processID, &status, 0) < 0, errno == EINTR {}
  }

  private static func makePipe() throws -> (read: Int32, write: Int32) {
    var descriptors = (Int32(0), Int32(0))
    let result = withUnsafeMutablePointer(to: &descriptors) { pointer in
      pointer.withMemoryRebound(to: Int32.self, capacity: 2) { values in
        Darwin.pipe(values)
      }
    }
    guard result == 0 else {
      throw MCPClientSessionError.connectionClosed
    }
    let readDescriptor = moveAboveStandardDescriptors(descriptors.0)
    guard readDescriptor >= 0 else {
      Darwin.close(descriptors.1)
      throw MCPClientSessionError.connectionClosed
    }
    let writeDescriptor = moveAboveStandardDescriptors(descriptors.1)
    guard writeDescriptor >= 0 else {
      Darwin.close(readDescriptor)
      throw MCPClientSessionError.connectionClosed
    }
    return (readDescriptor, writeDescriptor)
  }

  private static func makePipeSet() throws -> (
    input: (read: Int32, write: Int32),
    output: (read: Int32, write: Int32),
    error: (read: Int32, write: Int32)
  ) {
    let input = try makePipe()
    do {
      let output = try makePipe()
      do {
        let error = try makePipe()
        return (input, output, error)
      } catch {
        Darwin.close(output.read)
        Darwin.close(output.write)
        throw error
      }
    } catch {
      Darwin.close(input.read)
      Darwin.close(input.write)
      throw error
    }
  }

  private static func addCloseActions(
    _ actions: inout posix_spawn_file_actions_t?,
    descriptors: [Int32]
  ) -> Bool {
    descriptors.allSatisfy { descriptor in
      posix_spawn_file_actions_addclose(&actions, descriptor) == 0
    }
  }

  private static func setCloseOnExec(_ descriptor: Int32) -> Bool {
    let flags = fcntl(descriptor, F_GETFD)
    return flags >= 0 && fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0
  }

  private static func moveAboveStandardDescriptors(_ descriptor: Int32) -> Int32 {
    guard descriptor >= 0 else { return -1 }
    guard descriptor <= STDERR_FILENO else { return descriptor }
    let moved = fcntl(descriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
    Darwin.close(descriptor)
    return moved
  }

  private static func setNonblocking(_ descriptor: Int32) -> Bool {
    let flags = fcntl(descriptor, F_GETFL)
    return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
  }

  private static func withCStringVector<Result>(
    _ values: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
  ) throws -> Result {
    let pointers = values.map { value in
      value.withCString { strdup($0) }
    }
    guard pointers.allSatisfy({ $0 != nil }) else {
      for pointer in pointers {
        if let pointer { free(UnsafeMutableRawPointer(pointer)) }
      }
      throw MCPClientSessionError.connectionClosed
    }
    defer {
      for pointer in pointers {
        if let pointer { free(UnsafeMutableRawPointer(pointer)) }
      }
    }
    var terminated = pointers
    terminated.append(nil)
    return try terminated.withUnsafeMutableBufferPointer { buffer in
      guard let baseAddress = buffer.baseAddress else {
        throw MCPClientSessionError.connectionClosed
      }
      return try body(baseAddress)
    }
  }
}
