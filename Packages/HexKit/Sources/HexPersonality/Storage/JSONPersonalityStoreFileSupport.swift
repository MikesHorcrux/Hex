import Darwin
import Foundation

/// Shared file-system mechanics for the personality stores.
///
/// The support boundary deliberately has no JSON or policy knowledge. Callers provide the
/// bounded payload and remain responsible for decoding and validating their own records.
enum JSONPersonalityStoreFileSupport {
  enum Failure: Error, Equatable, Sendable {
    case invalidFileURL
    case unsafeFile
    case lockFailure
    case ioFailure
    case tooLarge
  }

  private static let lockRetryLimit = 40
  private static let lockRetryDelayMicroseconds: useconds_t = 25_000

  static func isValidFileURL(_ url: URL) -> Bool {
    let path = url.path
    let lastPathComponent = url.lastPathComponent
    return url.isFileURL
      && !path.isEmpty
      && path != "/"
      && path.hasPrefix("/")
      && path.utf8.count <= 4_096
      && !path.contains("\0")
      && !lastPathComponent.isEmpty
      && lastPathComponent != "."
      && lastPathComponent != ".."
      && !lastPathComponent.contains("/")
  }

  static func withFileLock<Result>(
    fileURL: URL,
    operation: () throws -> Result
  ) throws -> Result {
    try ensurePrivateDirectory(for: fileURL)
    let lockURL = fileURL.appendingPathExtension("lock")
    let descriptor = lockURL.path.withCString { path in
      Darwin.open(
        path,
        O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
        S_IRUSR | S_IWUSR
      )
    }
    guard descriptor >= 0 else {
      let openError = errno
      throw openError == ELOOP ? Failure.unsafeFile : Failure.lockFailure
    }

    defer {
      _ = Darwin.close(descriptor)
    }

    var lockStatus = stat()
    guard fstat(descriptor, &lockStatus) == 0 else {
      throw Failure.lockFailure
    }
    try validateRegularFile(lockStatus, permissions: 0o600)

    var didAcquire = false
    for attempt in 0..<lockRetryLimit {
      if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
        didAcquire = true
        break
      }
      let lockError = errno
      if lockError == EINTR {
        continue
      }
      guard lockError == EWOULDBLOCK || lockError == EAGAIN else {
        throw Failure.lockFailure
      }
      guard attempt + 1 < lockRetryLimit else {
        break
      }
      usleep(lockRetryDelayMicroseconds)
    }
    guard didAcquire else {
      throw Failure.lockFailure
    }
    defer {
      _ = flock(descriptor, LOCK_UN)
    }
    return try operation()
  }

  static func readBoundedData(
    from fileURL: URL,
    maximumBytes: Int
  ) throws -> Data? {
    let descriptor = fileURL.path.withCString { path in
      Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else {
      let openError = errno
      if openError == ENOENT {
        return nil
      }
      throw openError == ELOOP ? Failure.unsafeFile : Failure.ioFailure
    }
    defer {
      _ = Darwin.close(descriptor)
    }

    var initialStatus = stat()
    guard fstat(descriptor, &initialStatus) == 0 else {
      throw Failure.ioFailure
    }
    try validateRegularFile(initialStatus, permissions: 0o600)
    guard
      initialStatus.st_size >= 0,
      initialStatus.st_size <= off_t(maximumBytes),
      let expectedSize = Int(exactly: initialStatus.st_size)
    else {
      throw Failure.tooLarge
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
        throw Failure.ioFailure
      }
    }

    var finalStatus = stat()
    guard fstat(descriptor, &finalStatus) == 0 else {
      throw Failure.ioFailure
    }
    guard
      sameIdentity(initialStatus, finalStatus),
      finalStatus.st_size == initialStatus.st_size
    else {
      throw Failure.unsafeFile
    }
    return data
  }

  static func writeDurably(
    _ data: Data,
    to fileURL: URL,
    maximumBytes: Int
  ) throws {
    guard data.count <= maximumBytes else {
      throw Failure.tooLarge
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
      throw Failure.ioFailure
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
      throw Failure.ioFailure
    }
    try validateRegularFile(temporaryStatus, permissions: 0o600)
    try write(data, to: descriptor)
    guard Darwin.fsync(descriptor) == 0 else {
      throw Failure.ioFailure
    }
    guard Darwin.close(descriptor) == 0 else {
      descriptor = -1
      throw Failure.ioFailure
    }
    descriptor = -1

    let renameResult = temporaryURL.path.withCString { source in
      fileURL.path.withCString { destination in
        Darwin.rename(source, destination)
      }
    }
    guard renameResult == 0 else {
      throw Failure.ioFailure
    }
    didRename = true

    let finalDescriptor = fileURL.path.withCString { path in
      Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard finalDescriptor >= 0 else {
      throw Failure.unsafeFile
    }
    defer {
      _ = Darwin.close(finalDescriptor)
    }
    var finalStatus = stat()
    guard fstat(finalDescriptor, &finalStatus) == 0 else {
      throw Failure.ioFailure
    }
    try validateRegularFile(finalStatus, permissions: 0o600)
    guard sameIdentity(temporaryStatus, finalStatus) else {
      throw Failure.unsafeFile
    }

    let directoryDescriptor = directoryURL.path.withCString { path in
      Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard directoryDescriptor >= 0 else {
      throw Failure.unsafeFile
    }
    defer {
      _ = Darwin.close(directoryDescriptor)
    }
    var directoryStatus = stat()
    guard fstat(directoryDescriptor, &directoryStatus) == 0 else {
      throw Failure.ioFailure
    }
    try validatePrivateDirectory(directoryStatus)
    guard Darwin.fsync(directoryDescriptor) == 0 else {
      throw Failure.ioFailure
    }
  }

  private static func ensurePrivateDirectory(for fileURL: URL) throws {
    let directoryURL = fileURL.deletingLastPathComponent()
    let components = directoryURL.path.split(separator: "/", omittingEmptySubsequences: true)
    guard !components.isEmpty else {
      throw Failure.invalidFileURL
    }

    var currentURL = URL(fileURLWithPath: "/", isDirectory: true)
    var expectedDirectoryStatus: stat?
    for (index, component) in components.enumerated() {
      currentURL.appendPathComponent(String(component), isDirectory: true)
      var pathStatus = stat()
      if lstat(currentURL.path, &pathStatus) != 0 {
        guard errno == ENOENT else {
          throw Failure.unsafeFile
        }
        if Darwin.mkdir(currentURL.path, S_IRWXU) != 0, errno != EEXIST {
          throw Failure.ioFailure
        }
        guard lstat(currentURL.path, &pathStatus) == 0 else {
          throw Failure.ioFailure
        }
      }
      if pathStatus.st_mode & S_IFMT == S_IFLNK {
        guard isTrustedVarAlias(currentURL, status: pathStatus) else {
          throw Failure.unsafeFile
        }
      } else {
        guard pathStatus.st_mode & S_IFMT == S_IFDIR else {
          throw Failure.unsafeFile
        }
      }
      if index == components.count - 1 {
        expectedDirectoryStatus = pathStatus
      }
    }

    let descriptor = directoryURL.path.withCString { path in
      Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else {
      throw Failure.unsafeFile
    }
    defer {
      _ = Darwin.close(descriptor)
    }

    var descriptorStatus = stat()
    guard fstat(descriptor, &descriptorStatus) == 0 else {
      throw Failure.ioFailure
    }
    guard
      let expectedDirectoryStatus,
      sameIdentity(expectedDirectoryStatus, descriptorStatus)
    else {
      throw Failure.unsafeFile
    }
    try validatePrivateDirectory(descriptorStatus)
    guard fchmod(descriptor, S_IRWXU) == 0 else {
      throw Failure.ioFailure
    }
  }

  private static func validateExistingDestination(fileURL: URL) throws {
    var status = stat()
    guard lstat(fileURL.path, &status) == 0 else {
      guard errno == ENOENT else {
        throw Failure.unsafeFile
      }
      return
    }
    try validateRegularFile(status, permissions: 0o600)
  }

  private static func write(_ data: Data, to descriptor: Int32) throws {
    do {
      try data.withUnsafeBytes { rawBuffer in
        guard data.isEmpty || rawBuffer.baseAddress != nil else {
          throw Failure.ioFailure
        }
        var offset = 0
        while offset < data.count {
          guard let baseAddress = rawBuffer.baseAddress else {
            throw Failure.ioFailure
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
            throw Failure.ioFailure
          }
        }
      }
    } catch let error as Failure {
      throw error
    } catch {
      throw Failure.ioFailure
    }
  }

  private static func validateRegularFile(_ status: stat, permissions: mode_t) throws {
    guard
      status.st_mode & S_IFMT == S_IFREG,
      status.st_uid == geteuid(),
      status.st_nlink == 1,
      status.st_mode & 0o777 == permissions
    else {
      throw Failure.unsafeFile
    }
  }

  private static func validatePrivateDirectory(_ status: stat) throws {
    guard
      status.st_mode & S_IFMT == S_IFDIR,
      status.st_uid == geteuid(),
      status.st_mode & 0o777 == 0o700
    else {
      throw Failure.unsafeFile
    }
  }

  private static func isTrustedVarAlias(_ url: URL, status: stat) -> Bool {
    guard url.path == "/var", status.st_uid == 0 else {
      return false
    }
    var targetBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let resolved = url.path.withCString { path in
      realpath(path, &targetBuffer) != nil
    }
    guard resolved else {
      return false
    }
    let bytes = targetBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self) == "/private/var"
  }

  private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
  }
}
