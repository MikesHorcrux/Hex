import Darwin

extension POSIXProcessExecutor {
  func spawn(_ request: ProcessExecutionRequest) throws -> SpawnedProcess {
    var pipeDescriptors = (Int32(0), Int32(0))
    let pipeResult = withUnsafeMutablePointer(to: &pipeDescriptors) { pointer in
      pointer.withMemoryRebound(to: Int32.self, capacity: 2) { descriptors in
        Darwin.pipe(descriptors)
      }
    }
    guard pipeResult == 0 else {
      throw ProcessExecutionError.ioFailure
    }
    let readDescriptor = pipeDescriptors.0
    let writeDescriptor = pipeDescriptors.1
    var workingDirectoryDescriptor: Int32 = -1
    var fileActions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    var processID = pid_t(0)
    var didSpawn = false

    defer {
      if !didSpawn {
        Darwin.close(readDescriptor)
      }
      Darwin.close(writeDescriptor)
      if workingDirectoryDescriptor >= 0 {
        Darwin.close(workingDirectoryDescriptor)
      }
      if fileActions != nil {
        posix_spawn_file_actions_destroy(&fileActions)
      }
      if attributes != nil {
        posix_spawnattr_destroy(&attributes)
      }
    }

    guard
      setCloseOnExec(readDescriptor),
      setCloseOnExec(writeDescriptor),
      posix_spawn_file_actions_init(&fileActions) == 0,
      posix_spawnattr_init(&attributes) == 0
    else {
      throw ProcessExecutionError.ioFailure
    }

    workingDirectoryDescriptor = Darwin.open(
      request.workingDirectory.path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard workingDirectoryDescriptor >= 0 else {
      throw ProcessExecutionError.invalidRequest
    }

    guard
      posix_spawn_file_actions_addfchdir_np(
        &fileActions,
        workingDirectoryDescriptor
      ) == 0,
      posix_spawn_file_actions_addopen(
        &fileActions,
        STDIN_FILENO,
        "/dev/null",
        O_RDONLY,
        0
      ) == 0,
      posix_spawn_file_actions_adddup2(
        &fileActions,
        writeDescriptor,
        STDOUT_FILENO
      ) == 0,
      posix_spawn_file_actions_adddup2(
        &fileActions,
        writeDescriptor,
        STDERR_FILENO
      ) == 0,
      posix_spawn_file_actions_addclose(&fileActions, readDescriptor) == 0,
      posix_spawn_file_actions_addclose(&fileActions, writeDescriptor) == 0,
      posix_spawnattr_setflags(
        &attributes,
        Int16(POSIX_SPAWN_SETPGROUP) | Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
      ) == 0,
      posix_spawnattr_setpgroup(&attributes, 0) == 0
    else {
      throw ProcessExecutionError.ioFailure
    }

    let argumentValues = [request.executable.path] + request.arguments
    let environmentValues = request.environment
      .sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value)" }
    let spawnResult = try withCStringVector(argumentValues) { arguments in
      try withCStringVector(environmentValues) { environment in
        posix_spawn(
          &processID,
          request.executable.path,
          &fileActions,
          &attributes,
          arguments,
          environment
        )
      }
    }
    guard spawnResult == 0, processID > 0 else {
      throw ProcessExecutionError.spawnFailed
    }
    guard setNonblocking(readDescriptor) else {
      terminateAndReap(processID)
      throw ProcessExecutionError.ioFailure
    }
    didSpawn = true
    return SpawnedProcess(
      processID: processID,
      outputDescriptor: readDescriptor
    )
  }

  private func withCStringVector<Result>(
    _ values: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
  ) throws -> Result {
    let pointers: [UnsafeMutablePointer<CChar>?] = values.map { value in
      value.withCString { pointer in
        strdup(pointer)
      }
    }
    guard pointers.allSatisfy({ $0 != nil }) else {
      for pointer in pointers {
        free(pointer)
      }
      throw ProcessExecutionError.ioFailure
    }
    defer {
      for pointer in pointers {
        free(pointer)
      }
    }
    var terminatedPointers = pointers
    terminatedPointers.append(nil)
    return try terminatedPointers.withUnsafeMutableBufferPointer { buffer in
      guard let baseAddress = buffer.baseAddress else {
        throw ProcessExecutionError.ioFailure
      }
      return try body(baseAddress)
    }
  }

  private func setCloseOnExec(_ descriptor: Int32) -> Bool {
    let flags = fcntl(descriptor, F_GETFD)
    return flags >= 0 && fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0
  }

  private func setNonblocking(_ descriptor: Int32) -> Bool {
    let flags = fcntl(descriptor, F_GETFL)
    return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
  }
}
