import Darwin
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
  }

  public func load() async throws -> HexResidentRuntimeSettings? {
    try withFileLock {
      try readSettings()
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

    try withFileLock {
      try writeDurably(data)
    }
  }

  private func readSettings() throws -> HexResidentRuntimeSettings? {
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

    let data = try readBoundedData(from: descriptor)
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

  private func readBoundedData(from descriptor: Int32) throws -> Data {
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

  private func withFileLock<Result>(_ operation: () throws -> Result) throws -> Result {
    try ensurePrivateDirectory()
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

    do {
      var status = stat()
      guard fstat(descriptor, &status) == 0 else {
        throw JSONHexResidentRuntimeSettingsStoreError.lockFailure
      }
      try Self.validateRegularFile(status, permissions: 0o600)
      while flock(descriptor, LOCK_EX) != 0 {
        guard errno == EINTR else {
          throw JSONHexResidentRuntimeSettingsStoreError.lockFailure
        }
      }
      defer {
        _ = flock(descriptor, LOCK_UN)
      }
      return try operation()
    } catch let error as JSONHexResidentRuntimeSettingsStoreError {
      throw error
    } catch {
      throw JSONHexResidentRuntimeSettingsStoreError.lockFailure
    }
  }

  private func ensurePrivateDirectory() throws {
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

  private func writeDurably(_ data: Data) throws {
    try validateExistingDestination()
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

  private func validateExistingDestination() throws {
    var status = stat()
    guard lstat(fileURL.path, &status) == 0 else {
      guard errno == ENOENT else {
        throw JSONHexResidentRuntimeSettingsStoreError.unsafeFile
      }
      return
    }
    try Self.validateRegularFile(status, permissions: 0o600)
  }

  private func write(_ data: Data, to descriptor: Int32) throws {
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

  private static func validateRegularFile(_ status: stat, permissions: mode_t) throws {
    guard
      status.st_mode & S_IFMT == S_IFREG,
      status.st_uid == geteuid(),
      status.st_nlink == 1,
      status.st_mode & 0o777 == permissions
    else {
      throw JSONHexResidentRuntimeSettingsStoreError.unsafeFile
    }
  }

  private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
  }

  private static func isValidFileURL(_ url: URL) -> Bool {
    let path = url.path
    let lastPathComponent = url.lastPathComponent
    return url.isFileURL
      && !path.isEmpty
      && path.hasPrefix("/")
      && !path.contains("\0")
      && !lastPathComponent.isEmpty
      && lastPathComponent != "."
      && lastPathComponent != ".."
      && !lastPathComponent.contains("/")
  }
}
