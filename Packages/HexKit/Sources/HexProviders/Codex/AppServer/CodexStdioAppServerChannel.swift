import Darwin
import Foundation

/// A concrete stdio channel for an already-installed Codex app-server executable.
///
/// This type only launches the executable selected by the caller with the fixed `app-server`
/// argument default. It does not install, download, discover, or authenticate Codex. Account
/// credentials remain inside the Codex process and are never read by this channel.
public actor CodexStdioAppServerChannel: CodexAppServerChannel {
  public let executableURL: URL
  public let arguments: [String]
  public let workingDirectoryURL: URL

  private let environment: [String: String]
  private let maximumWriteBytes: Int
  private var process: SpawnedProcess?
  private var outputContinuation: AsyncThrowingStream<Data, any Error>.Continuation?
  private var outputReader: Task<Void, Never>?
  private var errorReader: Task<Void, Never>?

  public init(
    executableURL: URL,
    arguments: [String] = ["app-server"],
    environment: [String: String]? = nil,
    workingDirectoryURL: URL? = nil,
    maximumWriteBytes: Int = 8 * 1_024 * 1_024
  ) throws {
    let canonicalExecutable = executableURL.standardizedFileURL.resolvingSymlinksInPath()
    let canonicalWorkingDirectory =
      (workingDirectoryURL ?? FileManager.default.homeDirectoryForCurrentUser)
      .standardizedFileURL
      .resolvingSymlinksInPath()
    guard Self.isValidExecutableURL(canonicalExecutable) else {
      throw CodexStdioAppServerChannelError.invalidConfiguration
    }
    guard Self.isValidDirectoryURL(canonicalWorkingDirectory) else {
      throw CodexStdioAppServerChannelError.invalidConfiguration
    }
    guard Self.isValidArguments(arguments), (1...64 * 1_024 * 1_024).contains(maximumWriteBytes)
    else {
      throw CodexStdioAppServerChannelError.invalidConfiguration
    }
    self.executableURL = canonicalExecutable
    self.arguments = arguments
    self.environment = Self.environmentWithoutCredentials(
      environment ?? ProcessInfo.processInfo.environment
    )
    self.workingDirectoryURL = canonicalWorkingDirectory
    self.maximumWriteBytes = maximumWriteBytes
  }

  public func open(
    maximumReadBytes: Int
  ) async throws -> AsyncThrowingStream<Data, any Error> {
    try Task.checkCancellation()
    guard (1_024...64 * 1_024 * 1_024).contains(maximumReadBytes) else {
      throw CodexStdioAppServerChannelError.invalidConfiguration
    }
    guard process == nil else {
      throw CodexStdioAppServerChannelError.alreadyOpen
    }

    let spawned = try Self.spawn(
      executableURL: executableURL,
      arguments: arguments,
      environment: environment,
      workingDirectoryURL: workingDirectoryURL
    )
    let (stream, continuation) = AsyncThrowingStream.makeStream(
      of: Data.self,
      throwing: (any Error).self,
      bufferingPolicy: .bufferingOldest(32)
    )
    process = spawned
    outputContinuation = continuation
    let channel = self
    outputReader = Self.makeReader(
      descriptor: spawned.outputDescriptor,
      maximumReadBytes: maximumReadBytes,
      continuation: continuation,
      channel: channel
    )
    errorReader = Self.makeErrorReader(
      descriptor: spawned.errorDescriptor,
      channel: channel
    )
    continuation.onTermination = { @Sendable _ in
      Task {
        await channel.close()
      }
    }
    return stream
  }

  public func write(_ frame: Data) async throws {
    try Task.checkCancellation()
    guard !frame.isEmpty, frame.count <= maximumWriteBytes else {
      throw CodexStdioAppServerChannelError.outputLimitExceeded
    }
    guard let process else {
      throw CodexStdioAppServerChannelError.closed
    }

    var offset = 0
    while offset < frame.count {
      try Task.checkCancellation()
      guard self.process?.processID == process.processID else {
        throw CodexStdioAppServerChannelError.closed
      }
      let written = frame.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress else {
          return -1
        }
        return Darwin.write(
          process.inputDescriptor,
          baseAddress.advanced(by: offset),
          frame.count - offset
        )
      }
      if written > 0 {
        offset += written
      } else if written < 0, errno == EINTR {
        continue
      } else if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
        do {
          try await Task.sleep(for: .milliseconds(5))
        } catch is CancellationError {
          throw CancellationError()
        }
      } else {
        await finish(.ioFailure)
        throw CodexStdioAppServerChannelError.ioFailure
      }
    }
  }

  public func close() async {
    await finish(nil)
  }

  private func readerEnded() async {
    await finish(nil, waitForReaders: false)
  }

  private func readerFailed(_ error: CodexStdioAppServerChannelError) async {
    outputContinuation?.finish(throwing: error)
    await finish(error, waitForReaders: false)
  }

  private func finish(
    _ error: CodexStdioAppServerChannelError?,
    waitForReaders: Bool = true
  ) async {
    let activeProcess = process
    process = nil
    let continuation = outputContinuation
    outputContinuation = nil
    let activeOutputReader = outputReader
    let activeErrorReader = errorReader
    activeOutputReader?.cancel()
    activeErrorReader?.cancel()
    outputReader = nil
    errorReader = nil
    continuation?.finish(throwing: error)
    guard let activeProcess else {
      return
    }

    _ = Darwin.close(activeProcess.inputDescriptor)
    if Darwin.kill(-activeProcess.processID, SIGKILL) != 0 {
      _ = Darwin.kill(activeProcess.processID, SIGKILL)
    }
    var status = Int32(0)
    while waitpid(activeProcess.processID, &status, 0) < 0, errno == EINTR {}
    if waitForReaders {
      await activeOutputReader?.value
      await activeErrorReader?.value
    }
  }

  private struct SpawnedProcess: Sendable {
    let processID: pid_t
    let inputDescriptor: Int32
    let outputDescriptor: Int32
    let errorDescriptor: Int32
  }

  private static func makeReader(
    descriptor: Int32,
    maximumReadBytes: Int,
    continuation: AsyncThrowingStream<Data, any Error>.Continuation,
    channel: CodexStdioAppServerChannel
  ) -> Task<Void, Never> {
    Task.detached { [weak channel] in
      defer {
        _ = Darwin.close(descriptor)
      }
      var buffer = [UInt8](repeating: 0, count: min(maximumReadBytes, 64 * 1_024))
      while !Task.isCancelled {
        let count = buffer.withUnsafeMutableBytes { bytes in
          Darwin.read(descriptor, bytes.baseAddress, bytes.count)
        }
        if count > 0 {
          switch continuation.yield(Data(buffer.prefix(count))) {
          case .enqueued:
            continue
          case .dropped:
            continuation.finish(throwing: CodexStdioAppServerChannelError.outputLimitExceeded)
            await channel?.readerFailed(.outputLimitExceeded)
            return
          case .terminated:
            await channel?.readerEnded()
            return
          @unknown default:
            continuation.finish(throwing: CodexStdioAppServerChannelError.ioFailure)
            await channel?.readerFailed(.ioFailure)
            return
          }
        }
        if count == 0 {
          continuation.finish()
          await channel?.readerEnded()
          return
        }
        if errno == EINTR {
          continue
        }
        if errno == EAGAIN || errno == EWOULDBLOCK {
          do {
            try await Task.sleep(for: .milliseconds(5))
          } catch {
            return
          }
          continue
        }
        continuation.finish(throwing: CodexStdioAppServerChannelError.ioFailure)
        await channel?.readerFailed(.ioFailure)
        return
      }
    }
  }

  private static func makeErrorReader(
    descriptor: Int32,
    channel: CodexStdioAppServerChannel
  ) -> Task<Void, Never> {
    Task.detached { [weak channel] in
      defer {
        _ = Darwin.close(descriptor)
      }
      var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
      while !Task.isCancelled {
        let count = buffer.withUnsafeMutableBytes { bytes in
          Darwin.read(descriptor, bytes.baseAddress, bytes.count)
        }
        if count > 0 { continue }
        if count == 0 { return }
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK {
          do {
            try await Task.sleep(for: .milliseconds(5))
          } catch {
            return
          }
          continue
        }
        await channel?.readerFailed(.ioFailure)
        return
      }
    }
  }

  private static func spawn(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    workingDirectoryURL: URL
  ) throws -> SpawnedProcess {
    let input = try makePipe()
    let output: (read: Int32, write: Int32)
    do {
      output = try makePipe()
    } catch {
      Darwin.close(input.read)
      Darwin.close(input.write)
      throw error
    }
    let errorPipe: (read: Int32, write: Int32)
    do {
      errorPipe = try makePipe()
    } catch {
      Darwin.close(input.read)
      Darwin.close(input.write)
      Darwin.close(output.read)
      Darwin.close(output.write)
      throw error
    }

    var executableStatus = stat()
    guard lstat(executableURL.path, &executableStatus) == 0 else {
      closeAll(input, output, errorPipe)
      throw errno == ENOENT
        ? CodexStdioAppServerChannelError.executableUnavailable
        : CodexStdioAppServerChannelError.unsafeExecutable
    }
    guard isSafeExecutable(executableStatus), access(executableURL.path, X_OK) == 0 else {
      closeAll(input, output, errorPipe)
      throw CodexStdioAppServerChannelError.unsafeExecutable
    }
    var workingDirectoryStatus = stat()
    guard lstat(workingDirectoryURL.path, &workingDirectoryStatus) == 0,
      workingDirectoryStatus.st_mode & S_IFMT == S_IFDIR,
      workingDirectoryStatus.st_uid == geteuid()
    else {
      closeAll(input, output, errorPipe)
      throw CodexStdioAppServerChannelError.workingDirectoryUnavailable
    }

    let workingDirectoryDescriptor = moveAboveStandardDescriptors(
      Darwin.open(
        workingDirectoryURL.path,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
      )
    )
    guard workingDirectoryDescriptor >= 0 else {
      closeAll(input, output, errorPipe)
      throw CodexStdioAppServerChannelError.workingDirectoryUnavailable
    }
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    var processID = pid_t(0)
    var didSpawn = false
    defer {
      Darwin.close(input.read)
      Darwin.close(output.write)
      Darwin.close(errorPipe.write)
      if !didSpawn {
        Darwin.close(input.write)
        Darwin.close(output.read)
        Darwin.close(errorPipe.read)
      }
      Darwin.close(workingDirectoryDescriptor)
      if actions != nil { posix_spawn_file_actions_destroy(&actions) }
      if attributes != nil { posix_spawnattr_destroy(&attributes) }
    }

    guard
      posix_spawn_file_actions_init(&actions) == 0,
      posix_spawnattr_init(&attributes) == 0,
      posix_spawn_file_actions_addfchdir_np(&actions, workingDirectoryDescriptor) == 0,
      posix_spawn_file_actions_adddup2(&actions, input.read, STDIN_FILENO) == 0,
      posix_spawn_file_actions_adddup2(&actions, output.write, STDOUT_FILENO) == 0,
      posix_spawn_file_actions_adddup2(&actions, errorPipe.write, STDERR_FILENO) == 0,
      addCloseActions(
        &actions,
        descriptors: [
          input.read,
          input.write,
          output.read,
          output.write,
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
      throw CodexStdioAppServerChannelError.spawnFailed
    }

    let processArguments = [executableURL.path] + arguments
    let environmentValues =
      environment
      .sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value)" }
    let spawnResult = try withCStringVector(processArguments) { argumentVector in
      try withCStringVector(environmentValues) { environmentVector in
        posix_spawn(
          &processID,
          executableURL.path,
          &actions,
          &attributes,
          argumentVector,
          environmentVector
        )
      }
    }
    guard spawnResult == 0, processID > 0 else {
      throw CodexStdioAppServerChannelError.spawnFailed
    }
    guard setNonblocking(input.write), setNonblocking(output.read), setNonblocking(errorPipe.read)
    else {
      terminateImmediately(processID)
      throw CodexStdioAppServerChannelError.ioFailure
    }
    didSpawn = true
    return SpawnedProcess(
      processID: processID,
      inputDescriptor: input.write,
      outputDescriptor: output.read,
      errorDescriptor: errorPipe.read
    )
  }

  private static func makePipe() throws -> (read: Int32, write: Int32) {
    var descriptors = (Int32(0), Int32(0))
    guard
      withUnsafeMutablePointer(
        to: &descriptors,
        {
          $0.withMemoryRebound(to: Int32.self, capacity: 2) { Darwin.pipe($0) }
        }) == 0
    else {
      throw CodexStdioAppServerChannelError.ioFailure
    }
    let readDescriptor = moveAboveStandardDescriptors(descriptors.0)
    guard readDescriptor >= 0 else {
      Darwin.close(descriptors.1)
      throw CodexStdioAppServerChannelError.ioFailure
    }
    let writeDescriptor = moveAboveStandardDescriptors(descriptors.1)
    guard writeDescriptor >= 0 else {
      Darwin.close(readDescriptor)
      throw CodexStdioAppServerChannelError.ioFailure
    }
    return (readDescriptor, writeDescriptor)
  }

  private static func closeAll(
    _ input: (read: Int32, write: Int32),
    _ output: (read: Int32, write: Int32),
    _ errorPipe: (read: Int32, write: Int32)
  ) {
    Darwin.close(input.read)
    Darwin.close(input.write)
    Darwin.close(output.read)
    Darwin.close(output.write)
    Darwin.close(errorPipe.read)
    Darwin.close(errorPipe.write)
  }

  private static func addCloseActions(
    _ actions: inout posix_spawn_file_actions_t?,
    descriptors: [Int32]
  ) -> Bool {
    descriptors.allSatisfy { descriptor in
      posix_spawn_file_actions_addclose(&actions, descriptor) == 0
    }
  }

  private static func withCStringVector<Result>(
    _ values: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
  ) throws -> Result {
    let pointers: [UnsafeMutablePointer<CChar>?] = values.map { value in
      value.withCString { pointer in strdup(pointer) }
    }
    guard pointers.allSatisfy({ $0 != nil }) else {
      for pointer in pointers { free(pointer) }
      throw CodexStdioAppServerChannelError.ioFailure
    }
    defer {
      for pointer in pointers { free(pointer) }
    }
    var terminatedPointers = pointers
    terminatedPointers.append(nil)
    return try terminatedPointers.withUnsafeMutableBufferPointer { buffer in
      guard let baseAddress = buffer.baseAddress else {
        throw CodexStdioAppServerChannelError.ioFailure
      }
      return try body(baseAddress)
    }
  }

  private static func terminateImmediately(_ processID: pid_t) {
    guard processID > 0 else { return }
    if kill(-processID, SIGKILL) != 0 { _ = kill(processID, SIGKILL) }
    var status = Int32(0)
    while waitpid(processID, &status, 0) < 0, errno == EINTR {}
  }

  private static func moveAboveStandardDescriptors(_ descriptor: Int32) -> Int32 {
    guard descriptor >= 0 else { return -1 }
    guard descriptor > STDERR_FILENO else {
      let moved = fcntl(descriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
      Darwin.close(descriptor)
      return moved
    }
    return descriptor
  }

  private static func setNonblocking(_ descriptor: Int32) -> Bool {
    let flags = fcntl(descriptor, F_GETFL)
    return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
  }

  private static func environmentWithoutCredentials(
    _ environment: [String: String]
  ) -> [String: String] {
    environment.filter { key, value in
      !key.contains("\0")
        && !value.contains("\0")
        && !isCredentialEnvironmentKey(key)
    }
  }

  private static func isCredentialEnvironmentKey(_ key: String) -> Bool {
    let normalizedKey = key.uppercased()
    return [
      "API_KEY",
      "ACCESS_TOKEN",
      "REFRESH_TOKEN",
      "AUTH_TOKEN",
      "CLIENT_SECRET",
      "PASSWORD",
      "COOKIE",
      "SECRET",
    ].contains { normalizedKey.contains($0) }
  }

  private static func isSafeExecutable(_ status: stat) -> Bool {
    guard
      status.st_mode & S_IFMT == S_IFREG,
      status.st_uid == geteuid(),
      status.st_nlink == 1,
      status.st_mode & (S_IWGRP | S_IWOTH) == 0,
      status.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0
    else {
      return false
    }
    return true
  }

  private static func isValidExecutableURL(_ url: URL) -> Bool {
    let path = url.path
    return url.isFileURL && path.hasPrefix("/") && path != "/" && !path.contains("\0")
      && path.utf8.count <= 4_096
  }

  private static func isValidDirectoryURL(_ url: URL) -> Bool {
    isValidExecutableURL(url)
  }

  private static func isValidArguments(_ arguments: [String]) -> Bool {
    arguments.count <= 64
      && arguments.allSatisfy { argument in
        !argument.isEmpty && argument.utf8.count <= 4_096 && !argument.contains("\0")
      }
  }
}
