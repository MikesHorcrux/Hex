import Darwin
import Dispatch
import Foundation
import HexCore

/// A bounded, owner-only JSON store for non-secret resident runtime settings.
///
/// Reads and writes use a no-follow descriptor, an OS-backed lock, a private temporary file, and
/// synchronous file and directory flushes. The settings file never contains credentials.
public actor JSONHexResidentRuntimeSettingsStore: HexResidentRuntimeSettingsStore {
  public let fileURL: URL

  private let lockURL: URL
  private let maximumBytes: Int
  private let ioQueue: DispatchQueue

  private static let lockRetryLimit = 40
  private static let lockRetryDelayNanoseconds: UInt64 = 25 * 1_000_000

  public init(fileURL: URL, maximumBytes: Int = 64 * 1_024) throws {
    let standardizedURL = fileURL.standardizedFileURL
    guard Self.isValidFileURL(standardizedURL) else {
      throw JSONHexResidentRuntimeSettingsStoreError.invalidFileURL
    }
    guard (1...4 * 1_024 * 1_024).contains(maximumBytes) else {
      throw JSONHexResidentRuntimeSettingsStoreError.invalidMaximumBytes
    }

    self.fileURL = standardizedURL
    self.lockURL = standardizedURL.appendingPathExtension("lock")
    self.maximumBytes = maximumBytes
    self.ioQueue = DispatchQueue(
      label: "com.lunarmothstudios.Hex.resident-settings-\(UUID().uuidString)",
      qos: .utility
    )
  }

  public func load() async throws -> HexResidentRuntimeSettings? {
    let fileURL = self.fileURL
    let maximumBytes = self.maximumBytes
    return try await withFileLock {
      try Self.readSettings(fileURL: fileURL, maximumBytes: maximumBytes)
    }
  }

  public func save(_ settings: HexResidentRuntimeSettings) async throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data: Data
    do {
      data = try encoder.encode(settings)
    } catch {
      throw JSONHexResidentRuntimeSettingsStoreError.encodingFailure
    }
    guard data.count <= maximumBytes else {
      throw JSONHexResidentRuntimeSettingsStoreError.settingsTooLarge
    }

    let fileURL = self.fileURL
    let maximumBytes = self.maximumBytes
    try await withFileLock {
      try Self.writeDurably(data, fileURL: fileURL, maximumBytes: maximumBytes)
    }
  }

  private nonisolated static func readSettings(
    fileURL: URL,
    maximumBytes: Int
  ) throws -> HexResidentRuntimeSettings? {
    let descriptor = fileURL.path.withCString { path in
      Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else {
      let openError = errno
      if openError == ENOENT {
        return nil
      }
      if openError == ELOOP {
        throw JSONHexResidentRuntimeSettingsStoreError.unsafeFile
      }
      throw JSONHexResidentRuntimeSettingsStoreError.ioFailure
    }
    defer {
      _ = Darwin.close(descriptor)
    }

    let data = try readBoundedData(from: descriptor, maximumBytes: maximumBytes)
    do {
      return try JSONDecoder().decode(HexResidentRuntimeSettings.self, from: data)
    } catch is HexResidentRuntimeSettingsError {
      throw JSONHexResidentRuntimeSettingsStoreError.malformedSettings
    } catch is DecodingError {
      throw JSONHexResidentRuntimeSettingsStoreError.malformedSettings
    } catch {
      throw JSONHexResidentRuntimeSettingsStoreError.ioFailure
    }
  }

  private nonisolated static func readBoundedData(
    from descriptor: Int32,
    maximumBytes: Int
  ) throws -> Data {
    var initialStatus = stat()
    guard fstat(descriptor, &initialStatus) == 0 else {
      throw JSONHexResidentRuntimeSettingsStoreError.ioFailure
    }
    try Self.validateRegularFile(initialStatus, permissions: 0o600)
    guard
      initialStatus.st_size >= 0,
      initialStatus.st_size <= off_t(maximumBytes),
      let expectedSize = Int(exactly: initialStatus.st_size)
    else {
      throw JSONHexResidentRuntimeSettingsStoreError.settingsTooLarge
    }

    var data = Data()
    data.reserveCapacity(expectedSize)
    let bufferSize = min(maximumBytes, 64 * 1_024)
    var buffer = [UInt8](repeating: 0, count: bufferSize)
    var remaining = expectedSize
    while remaining > 0 {
      let requested = min(remaining, buffer.count)
      let count = buffer.withUnsafeMutableBytes { rawBuffer in
        Darwin.read(descriptor, rawBuffer.baseAddress, requested)
      }
      if count > 0 {
        data.append(contentsOf: buffer.prefix(count))
        remaining -= count
      } else if count < 0, errno == EINTR {
        continue
      } else {
        throw JSONHexResidentRuntimeSettingsStoreError.ioFailure
      }
    }

    var finalStatus = stat()
    guard fstat(descriptor, &finalStatus) == 0 else {
      throw JSONHexResidentRuntimeSettingsStoreError.ioFailure
    }
    guard
      Self.sameIdentity(initialStatus, finalStatus),
      finalStatus.st_size == initialStatus.st_size
    else {
      throw JSONHexResidentRuntimeSettingsStoreError.unsafeFile
    }
    return data
  }

  private func withFileLock<Result: Sendable>(
    _ operation: @escaping @Sendable () throws -> Result
  ) async throws -> Result {
    let fileURL = self.fileURL
    let lockURL = self.lockURL
    let ioQueue = self.ioQueue
    for attempt in 0..<Self.lockRetryLimit {
      try Task.checkCancellation()
      let lockAttempt = try await Self.perform(on: ioQueue) {
        try Self.withFileLockAttempt(
          fileURL: fileURL,
          lockURL: lockURL,
          operation: operation
        )
      }
      switch lockAttempt {
      case .acquired(let result):
        return result
      case .busy:
        guard attempt + 1 < Self.lockRetryLimit else {
          throw JSONHexResidentRuntimeSettingsStoreError.lockFailure
        }
        try await Task.sleep(nanoseconds: Self.lockRetryDelayNanoseconds)
      }
    }
    throw JSONHexResidentRuntimeSettingsStoreError.lockFailure
  }

  private nonisolated static func perform<Result: Sendable>(
    on queue: DispatchQueue,
    operation: @escaping @Sendable () throws -> Result
  ) async throws -> Result {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        do {
          continuation.resume(returning: try operation())
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private nonisolated static func withFileLockAttempt<Result: Sendable>(
    fileURL: URL,
    lockURL: URL,
    operation: () throws -> Result
  ) throws -> JSONHexResidentRuntimeSettingsLockAttempt<Result> {
    try ensurePrivateDirectory(for: fileURL)
    let descriptor = lockURL.path.withCString { path in
      Darwin.open(
        path,
        O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
        S_IRUSR | S_IWUSR
      )
    }
    guard descriptor >= 0 else {
      let openError = errno
      throw openError == ELOOP
        ? JSONHexResidentRuntimeSettingsStoreError.unsafeFile
        : JSONHexResidentRuntimeSettingsStoreError.lockFailure
    }

    defer {
      _ = Darwin.close(descriptor)
    }

    var status = stat()
    guard fstat(descriptor, &status) == 0 else {
      throw JSONHexResidentRuntimeSettingsStoreError.lockFailure
    }
    try Self.validateRegularFile(status, permissions: 0o600)

    guard flock(descriptor, LOCK_EX | LOCK_NB) != 0 else {
      defer {
        _ = flock(descriptor, LOCK_UN)
      }
      return .acquired(try operation())
    }
    let lockError = errno
    if lockError == EWOULDBLOCK || lockError == EAGAIN || lockError == EINTR {
      return .busy
    }
    throw JSONHexResidentRuntimeSettingsStoreError.lockFailure
  }

  private nonisolated static func ensurePrivateDirectory(for fileURL: URL) throws {
    try rejectSymlinkAncestors(for: fileURL)
    let directoryURL = fileURL.deletingLastPathComponent()
    var pathStatus = stat()
    if lstat(directoryURL.path, &pathStatus) != 0 {
      let pathError = errno
      guard pathError == ENOENT else {
        throw JSONHexResidentRuntimeSettingsStoreError.unsafeFile
      }
      if Darwin.mkdir(directoryURL.path, S_IRWXU) != 0 {
        guard errno == EEXIST else {
          throw JSONHexResidentRuntimeSettingsStoreError.ioFailure
        }
      }
      guard lstat(directoryURL.path, &pathStatus) == 0 else {
        throw JSONHexResidentRuntimeSettingsStoreError.ioFailure
      }
    }
    guard
      pathStatus.st_mode & S_IFMT == S_IFDIR,
      pathStatus.st_uid == geteuid()
    else {
      throw JSONHexResidentRuntimeSettingsStoreError.unsafeFile
    }

    let descriptor = directoryURL.path.withCString { path in
      Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else {
      throw JSONHexResidentRuntimeSettingsStoreError.unsafeFile
    }
    defer {
      _ = Darwin.close(descriptor)
    }

    var descriptorStatus = stat()
    guard fstat(descriptor, &descriptorStatus) == 0 else {
      throw JSONHexResidentRuntimeSettingsStoreError.ioFailure
    }
    guard
      descriptorStatus.st_mode & S_IFMT == S_IFDIR,
      descriptorStatus.st_uid == geteuid(),
      Self.sameIdentity(pathStatus, descriptorStatus)
    else {
      throw JSONHexResidentRuntimeSettingsStoreError.unsafeFile
    }
    guard fchmod(descriptor, S_IRWXU) == 0 else {
      throw JSONHexResidentRuntimeSettingsStoreError.ioFailure
    }
  }

  private nonisolated static func rejectSymlinkAncestors(for fileURL: URL) throws {
    let components = fileURL.path.split(separator: "/", omittingEmptySubsequences: true)
    guard !components.isEmpty else {
      throw JSONHexResidentRuntimeSettingsStoreError.invalidFileURL
    }

    var currentURL = URL(fileURLWithPath: "/", isDirectory: true)
    for component in components.dropLast() {
      currentURL.appendPathComponent(String(component), isDirectory: true)
      var status = stat()
      guard lstat(currentURL.path, &status) == 0 else {
        guard errno == ENOENT else {
          throw JSONHexResidentRuntimeSettingsStoreError.unsafeFile
        }
        break
      }
      guard status.st_mode & S_IFMT != S_IFLNK else {
        throw JSONHexResidentRuntimeSettingsStoreError.unsafeFile
      }
    }
  }

  private nonisolated static func writeDurably(
    _ data: Data,
    fileURL: URL,
    maximumBytes: Int
  ) throws {
    guard data.count <= maximumBytes else {
      throw JSONHexResidentRuntimeSettingsStoreError.settingsTooLarge
    }
    try validateExistingDestination(fileURL: fileURL)
    let directoryURL = fileURL.deletingLastPathComponent()
    let temporaryURL = directoryURL.appendingPathComponent(
      ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp",
      isDirectory: false
    )
    var descriptor = temporaryURL.path.withCString { path in
      Darwin.open(
        path,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        S_IRUSR | S_IWUSR
      )
    }
    guard descriptor >= 0 else {
      throw JSONHexResidentRuntimeSettingsStoreError.ioFailure
    }

    var didRename = false
    defer {
      if descriptor >= 0 {
        _ = Darwin.close(descriptor)
      }
      if !didRename {
        _ = temporaryURL.path.withCString { path in
          Darwin.unlink(path)
        }
      }
    }

    var temporaryStatus = stat()
    guard fstat(descriptor, &temporaryStatus) == 0 else {
      throw JSONHexResidentRuntimeSettingsStoreError.ioFailure
    }
    try Self.validateRegularFile(temporaryStatus, permissions: 0o600)
    try write(data, to: descriptor)
    guard Darwin.fsync(descriptor) == 0 else {
      throw JSONHexResidentRuntimeSettingsStoreError.ioFailure
    }
    guard Darwin.close(descriptor) == 0 else {
      descriptor = -1
      throw JSONHexResidentRuntimeSettingsStoreError.ioFailure
    }
    descriptor = -1

    let renameResult = temporaryURL.path.withCString { source in
      fileURL.path.withCString { destination in
        Darwin.rename(source, destination)
      }
    }
    guard renameResult == 0 else {
      throw JSONHexResidentRuntimeSettingsStoreError.ioFailure
    }
    didRename = true

    let finalDescriptor = fileURL.path.withCString { path in
      Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard finalDescriptor >= 0 else {
      throw JSONHexResidentRuntimeSettingsStoreError.unsafeFile
    }
    defer {
      _ = Darwin.close(finalDescriptor)
    }
    var finalStatus = stat()
    guard fstat(finalDescriptor, &finalStatus) == 0 else {
      throw JSONHexResidentRuntimeSettingsStoreError.ioFailure
    }
    try Self.validateRegularFile(finalStatus, permissions: 0o600)

    let directoryDescriptor = directoryURL.path.withCString { path in
      Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard directoryDescriptor >= 0 else {
      throw JSONHexResidentRuntimeSettingsStoreError.unsafeFile
    }
    defer {
      _ = Darwin.close(directoryDescriptor)
    }
    guard Darwin.fsync(directoryDescriptor) == 0 else {
      throw JSONHexResidentRuntimeSettingsStoreError.ioFailure
    }
  }

  private nonisolated static func validateExistingDestination(fileURL: URL) throws {
    var status = stat()
    guard lstat(fileURL.path, &status) == 0 else {
      guard errno == ENOENT else {
        throw JSONHexResidentRuntimeSettingsStoreError.unsafeFile
      }
      return
    }
    try Self.validateRegularFile(status, permissions: 0o600)
  }

  private nonisolated static func write(_ data: Data, to descriptor: Int32) throws {
    do {
      try data.withUnsafeBytes { rawBuffer in
        guard data.isEmpty || rawBuffer.baseAddress != nil else {
          throw JSONHexResidentRuntimeSettingsStoreError.ioFailure
        }
        var offset = 0
        while offset < data.count {
          guard let baseAddress = rawBuffer.baseAddress else {
            throw JSONHexResidentRuntimeSettingsStoreError.ioFailure
          }
          let written = Darwin.write(
            descriptor,
            baseAddress.advanced(by: offset),
            data.count - offset
          )
          if written > 0 {
            offset += written
          } else if written < 0, errno == EINTR {
            continue
          } else {
            throw JSONHexResidentRuntimeSettingsStoreError.ioFailure
          }
        }
      }
    } catch let error as JSONHexResidentRuntimeSettingsStoreError {
      throw error
    } catch {
      throw JSONHexResidentRuntimeSettingsStoreError.ioFailure
    }
  }

  private nonisolated static func validateRegularFile(_ status: stat, permissions: mode_t) throws {
    guard
      status.st_mode & S_IFMT == S_IFREG,
      status.st_uid == geteuid(),
      status.st_nlink == 1,
      status.st_mode & 0o777 == permissions
    else {
      throw JSONHexResidentRuntimeSettingsStoreError.unsafeFile
    }
  }

  private nonisolated static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
  }

  private nonisolated static func isValidFileURL(_ url: URL) -> Bool {
    let path = url.path
    let lastPathComponent = url.lastPathComponent
    return url.isFileURL
      && !path.isEmpty
      && path != "/"
      && path.hasPrefix("/")
      && !path.contains("\0")
      && !lastPathComponent.isEmpty
      && lastPathComponent != "."
      && lastPathComponent != ".."
      && !lastPathComponent.contains("/")
  }
}
