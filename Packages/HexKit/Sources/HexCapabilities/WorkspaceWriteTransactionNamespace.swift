import Darwin
import Foundation
import Synchronization

/// A same-volume, descriptor-owned namespace for atomic workspace writes.
///
/// The public pathname is used only to create and observe the namespace. Once opened, write
/// admission, publication cleanup, and durability operate relative to the held descriptor. The
/// directory is deliberately not name-deleted at teardown: another process running as the same
/// user can rename that public entry, and no final pathname check can make a later deletion safe.
/// Same-UID mutation of directory contents is outside the integrity boundary; cooperating writers
/// are serialized, and detected crash or foreign residue is bounded before a new write starts.
public final class WorkspaceWriteTransactionNamespace: Sendable {
  private static let maximumRetainedEntryCount = 64
  private static let reservedEntryCountPerWrite = 2

  let directoryURL: URL
  let directoryDescriptor: Int32

  private let directoryDevice: dev_t
  private let directoryInode: ino_t
  private let directoryOwner: uid_t
  private let criticalSection = Mutex<Void>(())

  public convenience init(appropriateFor root: URL) throws {
    guard root.isFileURL, root.path.hasPrefix("/"), !root.path.contains("\0") else {
      throw WorkspaceFileSystemError.invalidRoot
    }
    let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
    guard WorkspacePathScalarPolicy.isPromptSafe(canonicalRoot.path) else {
      throw WorkspaceFileSystemError.invalidRoot
    }
    let descriptor = Darwin.open(
      canonicalRoot.path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      throw WorkspaceFileSystemError.invalidRoot
    }
    defer { Darwin.close(descriptor) }
    try self.init(appropriateFor: canonicalRoot, targetDescriptor: descriptor)
  }

  init(appropriateFor targetURL: URL, targetDescriptor: Int32) throws {
    let namespaceURL: URL
    do {
      namespaceURL = try FileManager().url(
        for: .itemReplacementDirectory,
        in: .userDomainMask,
        appropriateFor: targetURL,
        create: true
      )
    } catch {
      throw WorkspaceFileSystemError.ioFailure
    }

    let descriptor = Darwin.open(
      namespaceURL.path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      throw WorkspaceFileSystemError.outcomeUncertain
    }

    var descriptorStatus = stat()
    var namedStatus = stat()
    var targetStatus = stat()
    let namespaceIsEmpty: Bool
    do {
      namespaceIsEmpty = try Self.entryCount(in: descriptor) == 0
    } catch {
      Darwin.close(descriptor)
      throw error
    }
    guard
      fstat(descriptor, &descriptorStatus) == 0,
      lstat(namespaceURL.path, &namedStatus) == 0,
      fstat(targetDescriptor, &targetStatus) == 0,
      descriptorStatus.st_mode & S_IFMT == S_IFDIR,
      namedStatus.st_mode & S_IFMT == S_IFDIR,
      targetStatus.st_mode & S_IFMT == S_IFDIR,
      descriptorStatus.st_dev == namedStatus.st_dev,
      descriptorStatus.st_ino == namedStatus.st_ino,
      descriptorStatus.st_dev == targetStatus.st_dev,
      descriptorStatus.st_uid == geteuid(),
      Self.removeInheritedAccessControlList(from: descriptor),
      fchflags(descriptor, 0) == 0,
      fchmod(descriptor, mode_t(0o700)) == 0,
      fstat(descriptor, &descriptorStatus) == 0,
      descriptorStatus.st_mode & S_IFMT == S_IFDIR,
      descriptorStatus.st_mode & mode_t(0o7777) == mode_t(0o700),
      descriptorStatus.st_flags == 0,
      descriptorStatus.st_uid == geteuid(),
      Self.hasNoExtendedAccessControlList(descriptor),
      namespaceIsEmpty,
      fsync(descriptor) == 0
    else {
      Darwin.close(descriptor)
      throw WorkspaceFileSystemError.outcomeUncertain
    }

    directoryURL = namespaceURL
    directoryDescriptor = descriptor
    directoryDevice = descriptorStatus.st_dev
    directoryInode = descriptorStatus.st_ino
    directoryOwner = descriptorStatus.st_uid
  }

  deinit {
    Darwin.close(directoryDescriptor)
  }

  func withExclusiveWriteAccess<Result>(
    targetDescriptor: Int32,
    _ operation: () throws -> Result
  ) throws -> Result {
    try criticalSection.withLock { _ in
      try Self.acquireFileLock(directoryDescriptor)
      defer { _ = flock(directoryDescriptor, LOCK_UN) }
      try validateAdmission(targetDescriptor: targetDescriptor)
      return try operation()
    }
  }

  func validateDescriptor() throws {
    var status = stat()
    guard
      fstat(directoryDescriptor, &status) == 0,
      status.st_mode & S_IFMT == S_IFDIR,
      status.st_dev == directoryDevice,
      status.st_ino == directoryInode,
      status.st_uid == directoryOwner,
      status.st_uid == geteuid(),
      status.st_mode & mode_t(0o7777) == mode_t(0o700),
      status.st_flags == 0,
      Self.hasNoExtendedAccessControlList(directoryDescriptor)
    else {
      throw WorkspaceFileSystemError.outcomeUncertain
    }
  }

  private func validateAdmission(targetDescriptor: Int32) throws {
    try validateDescriptor()
    var targetStatus = stat()
    guard
      fstat(targetDescriptor, &targetStatus) == 0,
      targetStatus.st_mode & S_IFMT == S_IFDIR,
      targetStatus.st_dev == directoryDevice
    else {
      throw WorkspaceFileSystemError.outcomeUncertain
    }
    let entryCount = try Self.entryCount(in: directoryDescriptor)
    guard
      entryCount
        <= Self.maximumRetainedEntryCount - Self.reservedEntryCountPerWrite
    else {
      throw WorkspaceFileSystemError.capacityExceeded
    }
  }

  private static func acquireFileLock(_ descriptor: Int32) throws {
    while flock(descriptor, LOCK_EX) != 0 {
      guard errno == EINTR else {
        throw WorkspaceFileSystemError.ioFailure
      }
    }
  }

  private static func entryCount(in descriptor: Int32) throws -> Int {
    let iteratorDescriptor = openat(
      descriptor,
      ".",
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard iteratorDescriptor >= 0 else {
      throw WorkspaceFileSystemError.ioFailure
    }
    guard let directory = fdopendir(iteratorDescriptor) else {
      Darwin.close(iteratorDescriptor)
      throw WorkspaceFileSystemError.ioFailure
    }
    defer { closedir(directory) }

    var count = 0
    while true {
      errno = 0
      guard let entry = readdir(directory) else {
        guard errno == 0 else {
          throw WorkspaceFileSystemError.ioFailure
        }
        return count
      }
      let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
          String(validatingCString: $0)
        }
      }
      guard let name else {
        throw WorkspaceFileSystemError.ioFailure
      }
      guard name != ".", name != ".." else {
        continue
      }
      let (nextCount, overflowed) = count.addingReportingOverflow(1)
      guard !overflowed, nextCount <= maximumRetainedEntryCount else {
        throw WorkspaceFileSystemError.capacityExceeded
      }
      count = nextCount
    }
  }

  private static func removeInheritedAccessControlList(from descriptor: Int32) -> Bool {
    guard let accessControlList = acl_init(1) else {
      return false
    }
    defer { _ = acl_free(UnsafeMutableRawPointer(accessControlList)) }
    return acl_set_fd_np(descriptor, accessControlList, ACL_TYPE_EXTENDED) == 0
  }

  private static func hasNoExtendedAccessControlList(_ descriptor: Int32) -> Bool {
    errno = 0
    guard let accessControlList = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
      return errno == ENOENT
    }
    _ = acl_free(UnsafeMutableRawPointer(accessControlList))
    return false
  }
}
