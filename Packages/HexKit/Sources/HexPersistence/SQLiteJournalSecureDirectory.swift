import Darwin
import Foundation

final class SQLiteJournalSecureDirectory {
  let databaseName: String
  let sqliteDatabaseURL: URL

  private let descriptor: Int32
  private let effectiveUserID: uid_t
  private let parentURL: URL

  init(databaseURL: URL) throws {
    let standardizedURL = databaseURL.standardizedFileURL
    let parentURL = standardizedURL.deletingLastPathComponent()
    let databaseName = standardizedURL.lastPathComponent
    guard
      parentURL.path != "/",
      parentURL.path != standardizedURL.path,
      !databaseName.isEmpty,
      databaseName != ".",
      databaseName != "..",
      !databaseName.contains("/")
    else {
      throw SQLiteAgentEventJournalError.invalidConfiguration(
        "The database must live in a dedicated non-root directory."
      )
    }

    var pathStatus = stat()
    if lstat(parentURL.path, &pathStatus) != 0 {
      let pathError = errno
      guard pathError == ENOENT else {
        throw Self.systemError(pathError)
      }
      guard Darwin.mkdir(parentURL.path, S_IRWXU) == 0 else {
        let createError = errno
        throw SQLiteAgentEventJournalError.invalidConfiguration(
          "The dedicated database directory could not be created: \(String(cString: strerror(createError)))."
        )
      }
      guard lstat(parentURL.path, &pathStatus) == 0 else {
        throw Self.systemError(errno)
      }
    }

    guard pathStatus.st_mode & S_IFMT == S_IFDIR else {
      throw SQLiteAgentEventJournalError.invalidConfiguration(
        "The database parent path must be a real directory, not a symlink or special file."
      )
    }

    let effectiveUserID = geteuid()
    guard pathStatus.st_uid == effectiveUserID else {
      throw SQLiteAgentEventJournalError.invalidConfiguration(
        "The database directory must be owned by the current user."
      )
    }

    let descriptor = Darwin.open(
      parentURL.path,
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
      throw Self.systemError(errno)
    }

    do {
      var descriptorStatus = stat()
      guard fstat(descriptor, &descriptorStatus) == 0 else {
        throw Self.systemError(errno)
      }
      guard
        descriptorStatus.st_mode & S_IFMT == S_IFDIR,
        descriptorStatus.st_uid == effectiveUserID,
        Self.sameIdentity(pathStatus, descriptorStatus)
      else {
        throw SQLiteAgentEventJournalError.invalidConfiguration(
          "The database directory changed while it was being secured."
        )
      }
      guard fchmod(descriptor, S_IRWXU) == 0 else {
        throw Self.systemError(errno)
      }

      let resolvedParentURL = URL(
        fileURLWithPath: try Self.canonicalPath(for: parentURL.path),
        isDirectory: true
      )
      var resolvedStatus = stat()
      guard
        lstat(resolvedParentURL.path, &resolvedStatus) == 0,
        Self.sameIdentity(resolvedStatus, descriptorStatus)
      else {
        throw SQLiteAgentEventJournalError.invalidConfiguration(
          "The database directory could not be anchored to a canonical path."
        )
      }

      self.databaseName = databaseName
      self.sqliteDatabaseURL = resolvedParentURL.appendingPathComponent(
        databaseName,
        isDirectory: false
      )
      self.descriptor = descriptor
      self.effectiveUserID = effectiveUserID
      self.parentURL = parentURL
      try validateParentIdentity()
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  deinit {
    Darwin.close(descriptor)
  }

  func openDatabaseFile() throws -> Int32 {
    try openOwnedRegularFile(named: databaseName, createIfMissing: true)
  }

  func openLockFile() throws -> Int32 {
    try openOwnedRegularFile(named: databaseName + ".lock", createIfMissing: true)
  }

  func hardenSQLiteFiles() throws {
    try validateParentIdentity()
    for name in [
      databaseName, databaseName + "-wal", databaseName + "-shm", databaseName + ".lock",
    ] {
      try hardenFileIfPresent(named: name)
    }
  }

  func validateDatabaseIdentity(descriptor databaseDescriptor: Int32) throws {
    try validateParentIdentity()
    let descriptorStatus = try status(for: databaseDescriptor)
    guard
      descriptorStatus.st_mode & S_IFMT == S_IFREG,
      descriptorStatus.st_uid == effectiveUserID,
      descriptorStatus.st_nlink == 1
    else {
      throw SQLiteAgentEventJournalError.invalidConfiguration(
        "The database must remain a single-link regular file owned by the current user."
      )
    }
    guard let pathStatus = try anchoredStatus(named: databaseName) else {
      throw SQLiteAgentEventJournalError.invalidConfiguration(
        "The database path disappeared while the journal was open."
      )
    }
    guard
      pathStatus.st_mode & S_IFMT == S_IFREG,
      pathStatus.st_uid == effectiveUserID,
      pathStatus.st_nlink == 1,
      Self.sameIdentity(pathStatus, descriptorStatus)
    else {
      throw SQLiteAgentEventJournalError.invalidConfiguration(
        "The database path changed identity or gained a hard-link alias."
      )
    }
  }

  private func openOwnedRegularFile(
    named name: String,
    createIfMissing: Bool
  ) throws -> Int32 {
    if let existingStatus = try anchoredStatus(named: name) {
      try validateRegularFile(existingStatus, named: name)
    } else if !createIfMissing {
      throw SQLiteAgentEventJournalError.invalidConfiguration(
        "The required journal file \(name) is missing."
      )
    }

    var flags = O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
    if createIfMissing {
      flags |= O_CREAT
    }
    let fileDescriptor = Darwin.openat(
      descriptor,
      name,
      flags,
      S_IRUSR | S_IWUSR
    )
    guard fileDescriptor >= 0 else {
      let openError = errno
      if openError == ELOOP {
        throw SQLiteAgentEventJournalError.invalidConfiguration(
          "The journal path \(name) must not be a symbolic link."
        )
      }
      throw Self.systemError(openError)
    }

    do {
      let descriptorStatus = try status(for: fileDescriptor)
      try validateRegularFile(descriptorStatus, named: name)
      guard fchmod(fileDescriptor, S_IRUSR | S_IWUSR) == 0 else {
        throw Self.systemError(errno)
      }
      let hardenedStatus = try status(for: fileDescriptor)
      guard
        let pathStatus = try anchoredStatus(named: name),
        hardenedStatus.st_mode & 0o777 == S_IRUSR | S_IWUSR,
        hardenedStatus.st_uid == effectiveUserID,
        hardenedStatus.st_nlink == 1,
        Self.sameIdentity(pathStatus, hardenedStatus)
      else {
        throw SQLiteAgentEventJournalError.invalidConfiguration(
          "The journal path \(name) changed while it was being opened."
        )
      }
      return fileDescriptor
    } catch {
      Darwin.close(fileDescriptor)
      throw error
    }
  }

  private func hardenFileIfPresent(named name: String) throws {
    guard let pathStatus = try anchoredStatus(named: name) else {
      return
    }
    try validateRegularFile(pathStatus, named: name)
    let fileDescriptor = try openOwnedRegularFile(named: name, createIfMissing: false)
    Darwin.close(fileDescriptor)
  }

  private func validateParentIdentity() throws {
    var pathStatus = stat()
    guard lstat(parentURL.path, &pathStatus) == 0 else {
      throw Self.systemError(errno)
    }
    let descriptorStatus = try status(for: descriptor)
    guard
      pathStatus.st_mode & S_IFMT == S_IFDIR,
      descriptorStatus.st_mode & S_IFMT == S_IFDIR,
      pathStatus.st_uid == effectiveUserID,
      descriptorStatus.st_uid == effectiveUserID,
      Self.sameIdentity(pathStatus, descriptorStatus),
      descriptorStatus.st_mode & 0o777 == S_IRWXU
    else {
      throw SQLiteAgentEventJournalError.invalidConfiguration(
        "The dedicated database directory changed identity, ownership, or permissions."
      )
    }
  }

  private func anchoredStatus(named name: String) throws -> stat? {
    var fileStatus = stat()
    guard fstatat(descriptor, name, &fileStatus, AT_SYMLINK_NOFOLLOW) == 0 else {
      let statusError = errno
      if statusError == ENOENT {
        return nil
      }
      throw Self.systemError(statusError)
    }
    return fileStatus
  }

  private func status(for fileDescriptor: Int32) throws -> stat {
    var fileStatus = stat()
    guard fstat(fileDescriptor, &fileStatus) == 0 else {
      throw Self.systemError(errno)
    }
    return fileStatus
  }

  private func validateRegularFile(_ fileStatus: stat, named name: String) throws {
    guard fileStatus.st_mode & S_IFMT == S_IFREG else {
      throw SQLiteAgentEventJournalError.invalidConfiguration(
        "The journal path \(name) must be a regular file."
      )
    }
    guard fileStatus.st_uid == effectiveUserID else {
      throw SQLiteAgentEventJournalError.invalidConfiguration(
        "The journal path \(name) must be owned by the current user."
      )
    }
    guard fileStatus.st_nlink == 1 else {
      throw SQLiteAgentEventJournalError.invalidConfiguration(
        "The journal path \(name) must not have hard-link aliases."
      )
    }
  }

  private static func sameIdentity(_ left: stat, _ right: stat) -> Bool {
    left.st_dev == right.st_dev && left.st_ino == right.st_ino
  }

  private static func canonicalPath(for path: String) throws -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let result = path.withCString { pathPointer in
      realpath(pathPointer, &buffer)
    }
    guard result != nil else {
      throw systemError(errno)
    }
    let codeUnits = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: codeUnits, as: UTF8.self)
  }

  private static func systemError(_ code: Int32) -> SQLiteAgentEventJournalError {
    .database(code: code, message: String(cString: strerror(code)))
  }
}
