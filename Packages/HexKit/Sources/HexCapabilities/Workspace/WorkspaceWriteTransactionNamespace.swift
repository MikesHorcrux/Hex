import Darwin
import Foundation
import Synchronization

/// A bounded, same-volume namespace for atomic workspace writes.
///
/// A fixed, UID-owned admission directory contains at most 64 reusable runtime slots. Each live
/// namespace retains an exclusive lock on one slot descriptor, while writes take the admission
/// directory lock so cooperating runtimes and processes serialize publication. Slot and admission
/// names are never removed automatically: teardown only closes owned descriptors. A clean slot can
/// be reused after that descriptor closes, and bounded crash residue is inspected relative to the
/// newly opened descriptor before reuse.
///
/// Deliberate replacement by another process running as the same UID is outside the integrity
/// boundary. Once admission succeeds, later work remains bound to the retained descriptors and
/// never recursively deletes whatever may subsequently appear at their former public names.
public final class WorkspaceWriteTransactionNamespace: Sendable {
  public static let maximumRuntimeSlotCount = 64

  private static let maximumRetainedEntryCount = 64
  private static let reservedEntryCountPerWrite = 2
  private static let admissionDirectoryPrefix = ".hex-workspace-write-transactions-v1"

  public let usage: WorkspaceWriteTransactionNamespaceUsage

  let directoryURL: URL
  let directoryDescriptor: Int32

  private let admissionDirectoryDescriptor: Int32
  private let admissionDirectoryDevice: dev_t
  private let admissionDirectoryInode: ino_t
  private let admissionDirectoryOwner: uid_t
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

  init(
    appropriateFor targetURL: URL,
    targetDescriptor: Int32,
    admissionDirectoryURL: URL? = nil,
    maximumSlotCount: Int = WorkspaceWriteTransactionNamespace.maximumRuntimeSlotCount,
    openSlot: (Int32, String) -> Int32 = {
      Darwin.openat($0, $1, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    },
    inspectSlot: (Int32, UnsafeMutablePointer<stat>) -> Int32 = { Darwin.fstat($0, $1) }
  ) throws {
    guard
      targetURL.isFileURL,
      targetURL.path.hasPrefix("/"),
      !targetURL.path.contains("\0"),
      (1...Self.maximumRuntimeSlotCount).contains(maximumSlotCount)
    else {
      throw WorkspaceFileSystemError.invalidRoot
    }

    let requestedAdmissionURL = admissionDirectoryURL ?? Self.defaultAdmissionDirectoryURL()
    let preparedAdmission = try Self.prepareAdmissionDirectory(
      at: requestedAdmissionURL,
      targetDescriptor: targetDescriptor,
      maximumSlotCount: maximumSlotCount
    )
    var retainsAdmissionDescriptor = false
    defer {
      if !retainsAdmissionDescriptor {
        Darwin.close(preparedAdmission.descriptor)
      }
    }

    try Self.acquireFileLock(preparedAdmission.descriptor)
    var retainsAdmissionLock = true
    defer {
      if retainsAdmissionLock {
        _ = flock(preparedAdmission.descriptor, LOCK_UN)
      }
    }
    defer { Darwin.close(preparedAdmission.parentDescriptor) }
    try Self.validateNamedDirectory(
      descriptor: preparedAdmission.descriptor,
      expectedStatus: preparedAdmission.status,
      named: preparedAdmission.name,
      in: preparedAdmission.parentDescriptor
    )

    var claimedDescriptor: Int32 = -1
    var claimedSlotIndex: Int?
    var claimedURL: URL?
    var unavailableSlotCount = 0
    for index in 0..<maximumSlotCount {
      let slotName = Self.slotName(for: index)
      let slotURL = preparedAdmission.url.appending(
        path: slotName,
        directoryHint: .isDirectory
      )
      let createdSlot: Bool
      if mkdirat(preparedAdmission.descriptor, slotName, mode_t(0o700)) == 0 {
        createdSlot = true
        guard fsync(preparedAdmission.descriptor) == 0 else {
          unavailableSlotCount += 1
          continue
        }
      } else if errno == EEXIST {
        createdSlot = false
      } else {
        unavailableSlotCount += 1
        continue
      }

      let descriptor = openSlot(preparedAdmission.descriptor, slotName)
      guard descriptor >= 0 else {
        unavailableSlotCount += 1
        continue
      }
      var retainsSlotDescriptor = false
      defer {
        if !retainsSlotDescriptor {
          Darwin.close(descriptor)
        }
      }

      guard
        Self.prepareAndValidateSlot(
          descriptor: descriptor,
          named: slotName,
          in: preparedAdmission.descriptor,
          expectedDevice: preparedAdmission.status.st_dev,
          created: createdSlot,
          inspectSlot: inspectSlot
        ),
        Self.acquireLifetimeLock(descriptor),
        Self.prepareAndValidateSlot(
          descriptor: descriptor,
          named: slotName,
          in: preparedAdmission.descriptor,
          expectedDevice: preparedAdmission.status.st_dev,
          created: false,
          inspectSlot: inspectSlot
        ),
        (try? Self.entryCount(in: descriptor))
          .map({ $0 <= Self.maximumRetainedEntryCount - Self.reservedEntryCountPerWrite }) == true
      else {
        unavailableSlotCount += 1
        continue
      }

      claimedDescriptor = descriptor
      claimedSlotIndex = index
      claimedURL = slotURL
      retainsSlotDescriptor = true
      break
    }

    guard claimedDescriptor >= 0, let claimedSlotIndex, let claimedURL else {
      let usage = WorkspaceWriteTransactionNamespaceUsage(
        claimedSlotCount: 0,
        unavailableSlotCount: unavailableSlotCount,
        availableSlotCount: maximumSlotCount - unavailableSlotCount,
        maximumSlotCount: maximumSlotCount
      )
      throw WorkspaceWriteTransactionNamespaceError.exhausted(usage)
    }

    let availability = Self.remainingAvailability(
      excluding: claimedSlotIndex,
      in: preparedAdmission.descriptor,
      expectedDevice: preparedAdmission.status.st_dev,
      maximumSlotCount: maximumSlotCount,
      openSlot: openSlot,
      inspectSlot: inspectSlot
    )
    var claimedStatus = stat()
    guard inspectSlot(claimedDescriptor, &claimedStatus) == 0 else {
      Darwin.close(claimedDescriptor)
      throw WorkspaceFileSystemError.outcomeUncertain
    }

    directoryURL = claimedURL
    directoryDescriptor = claimedDescriptor
    directoryDevice = claimedStatus.st_dev
    directoryInode = claimedStatus.st_ino
    directoryOwner = claimedStatus.st_uid
    admissionDirectoryDescriptor = preparedAdmission.descriptor
    admissionDirectoryDevice = preparedAdmission.status.st_dev
    admissionDirectoryInode = preparedAdmission.status.st_ino
    admissionDirectoryOwner = preparedAdmission.status.st_uid
    usage = WorkspaceWriteTransactionNamespaceUsage(
      claimedSlotCount: 1,
      unavailableSlotCount: availability.unavailable,
      availableSlotCount: availability.available,
      maximumSlotCount: maximumSlotCount
    )
    retainsAdmissionDescriptor = true
    retainsAdmissionLock = false
    _ = flock(preparedAdmission.descriptor, LOCK_UN)
  }

  deinit {
    Darwin.close(directoryDescriptor)
    Darwin.close(admissionDirectoryDescriptor)
  }

  func withExclusiveWriteAccess<Result>(
    targetDescriptor: Int32,
    _ operation: () throws -> Result
  ) throws -> Result {
    try criticalSection.withLock { _ in
      try Self.acquireFileLock(admissionDirectoryDescriptor)
      defer { _ = flock(admissionDirectoryDescriptor, LOCK_UN) }
      try validateAdmission(targetDescriptor: targetDescriptor)
      return try operation()
    }
  }

  func validateDescriptor() throws {
    try Self.validateRetainedDirectory(
      descriptor: admissionDirectoryDescriptor,
      device: admissionDirectoryDevice,
      inode: admissionDirectoryInode,
      owner: admissionDirectoryOwner
    )
    try Self.validateRetainedDirectory(
      descriptor: directoryDescriptor,
      device: directoryDevice,
      inode: directoryInode,
      owner: directoryOwner
    )
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

  private static func defaultAdmissionDirectoryURL() -> URL {
    FileManager.default.temporaryDirectory
      .standardizedFileURL
      .resolvingSymlinksInPath()
      .appending(
        path: "\(admissionDirectoryPrefix)-uid-\(geteuid())",
        directoryHint: .isDirectory
      )
  }

  private static func prepareAdmissionDirectory(
    at requestedURL: URL,
    targetDescriptor: Int32,
    maximumSlotCount: Int
  ) throws -> (url: URL, name: String, descriptor: Int32, parentDescriptor: Int32, status: stat) {
    guard
      requestedURL.isFileURL,
      requestedURL.path.hasPrefix("/"),
      !requestedURL.path.contains("\0")
    else {
      throw WorkspaceFileSystemError.invalidRoot
    }
    let canonicalTemporaryDirectory = FileManager.default.temporaryDirectory
      .standardizedFileURL
      .resolvingSymlinksInPath()
    let canonicalParent = requestedURL.deletingLastPathComponent()
      .standardizedFileURL
      .resolvingSymlinksInPath()
    let name = requestedURL.lastPathComponent
    guard
      canonicalParent == canonicalTemporaryDirectory,
      !name.isEmpty,
      name != ".",
      name != "..",
      !name.contains("/"),
      WorkspacePathScalarPolicy.isPromptSafe(name)
    else {
      throw WorkspaceFileSystemError.invalidRoot
    }
    let canonicalURL = canonicalParent.appending(path: name, directoryHint: .isDirectory)
    let parentDescriptor = Darwin.open(
      canonicalParent.path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard parentDescriptor >= 0 else {
      throw WorkspaceFileSystemError.invalidRoot
    }
    var retainsParentDescriptor = false
    defer {
      if !retainsParentDescriptor {
        Darwin.close(parentDescriptor)
      }
    }
    var parentStatus = stat()
    var targetStatus = stat()
    guard
      fstat(parentDescriptor, &parentStatus) == 0,
      fstat(targetDescriptor, &targetStatus) == 0,
      parentStatus.st_mode & S_IFMT == S_IFDIR,
      targetStatus.st_mode & S_IFMT == S_IFDIR,
      parentStatus.st_uid == geteuid(),
      parentStatus.st_dev == targetStatus.st_dev
    else {
      throw WorkspaceFileSystemError.outcomeUncertain
    }

    let createdAdmissionDirectory: Bool
    if mkdirat(parentDescriptor, name, mode_t(0o700)) == 0 {
      createdAdmissionDirectory = true
      guard fsync(parentDescriptor) == 0 else {
        throw WorkspaceFileSystemError.outcomeUncertain
      }
    } else if errno == EEXIST {
      createdAdmissionDirectory = false
    } else {
      throw WorkspaceFileSystemError.ioFailure
    }
    let descriptor = openat(
      parentDescriptor,
      name,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      throw WorkspaceFileSystemError.outcomeUncertain
    }
    var retainsDescriptor = false
    defer {
      if !retainsDescriptor {
        Darwin.close(descriptor)
      }
    }
    if createdAdmissionDirectory {
      guard
        removeInheritedAccessControlList(from: descriptor),
        fchflags(descriptor, 0) == 0,
        fchmod(descriptor, mode_t(0o700)) == 0,
        fsync(descriptor) == 0
      else {
        throw WorkspaceFileSystemError.outcomeUncertain
      }
    }
    var status = stat()
    var namedStatus = stat()
    guard
      fstat(descriptor, &status) == 0,
      fstatat(parentDescriptor, name, &namedStatus, AT_SYMLINK_NOFOLLOW) == 0,
      Self.statusIsSecureDirectory(status, expectedDevice: targetStatus.st_dev),
      Self.hasNoExtendedAccessControlList(descriptor),
      namedStatus.st_mode & S_IFMT == S_IFDIR,
      namedStatus.st_dev == status.st_dev,
      namedStatus.st_ino == status.st_ino,
      try Self.entryNames(in: descriptor, maximumCount: maximumSlotCount)
        .allSatisfy({ Self.isSlotName($0, maximumSlotCount: maximumSlotCount) })
    else {
      throw WorkspaceFileSystemError.outcomeUncertain
    }
    retainsDescriptor = true
    retainsParentDescriptor = true
    return (canonicalURL, name, descriptor, parentDescriptor, status)
  }

  private static func prepareAndValidateSlot(
    descriptor: Int32,
    named name: String,
    in parentDescriptor: Int32,
    expectedDevice: dev_t,
    created: Bool,
    inspectSlot: (Int32, UnsafeMutablePointer<stat>) -> Int32
  ) -> Bool {
    if created {
      guard
        removeInheritedAccessControlList(from: descriptor),
        fchflags(descriptor, 0) == 0,
        fchmod(descriptor, mode_t(0o700)) == 0,
        fsync(descriptor) == 0,
        fsync(parentDescriptor) == 0
      else {
        return false
      }
    }
    var descriptorStatus = stat()
    var namedStatus = stat()
    guard
      inspectSlot(descriptor, &descriptorStatus) == 0,
      fstatat(parentDescriptor, name, &namedStatus, AT_SYMLINK_NOFOLLOW) == 0,
      statusIsSecureDirectory(descriptorStatus, expectedDevice: expectedDevice),
      hasNoExtendedAccessControlList(descriptor),
      namedStatus.st_mode & S_IFMT == S_IFDIR,
      namedStatus.st_dev == descriptorStatus.st_dev,
      namedStatus.st_ino == descriptorStatus.st_ino
    else {
      return false
    }
    return true
  }

  private static func remainingAvailability(
    excluding claimedSlotIndex: Int,
    in admissionDescriptor: Int32,
    expectedDevice: dev_t,
    maximumSlotCount: Int,
    openSlot: (Int32, String) -> Int32,
    inspectSlot: (Int32, UnsafeMutablePointer<stat>) -> Int32
  ) -> (available: Int, unavailable: Int) {
    var available = 0
    var unavailable = 0
    for index in 0..<maximumSlotCount {
      guard index != claimedSlotIndex else {
        continue
      }
      let slotName = slotName(for: index)
      var namedStatus = stat()
      if fstatat(admissionDescriptor, slotName, &namedStatus, AT_SYMLINK_NOFOLLOW) != 0 {
        if errno == ENOENT {
          available += 1
        } else {
          unavailable += 1
        }
        continue
      }
      let descriptor = openSlot(admissionDescriptor, slotName)
      guard descriptor >= 0 else {
        unavailable += 1
        continue
      }
      defer { Darwin.close(descriptor) }
      guard
        prepareAndValidateSlot(
          descriptor: descriptor,
          named: slotName,
          in: admissionDescriptor,
          expectedDevice: expectedDevice,
          created: false,
          inspectSlot: inspectSlot
        ),
        acquireLifetimeLock(descriptor),
        (try? entryCount(in: descriptor))
          .map({ $0 <= maximumRetainedEntryCount - reservedEntryCountPerWrite }) == true
      else {
        unavailable += 1
        continue
      }
      _ = flock(descriptor, LOCK_UN)
      available += 1
    }
    return (available, unavailable)
  }

  private static func validateNamedDirectory(
    descriptor: Int32,
    expectedStatus: stat,
    named name: String,
    in parentDescriptor: Int32
  ) throws {
    var descriptorStatus = stat()
    var namedStatus = stat()
    guard
      fstat(descriptor, &descriptorStatus) == 0,
      fstatat(parentDescriptor, name, &namedStatus, AT_SYMLINK_NOFOLLOW) == 0,
      descriptorStatus.st_dev == expectedStatus.st_dev,
      descriptorStatus.st_ino == expectedStatus.st_ino,
      namedStatus.st_mode & S_IFMT == S_IFDIR,
      namedStatus.st_dev == descriptorStatus.st_dev,
      namedStatus.st_ino == descriptorStatus.st_ino,
      statusIsSecureDirectory(descriptorStatus, expectedDevice: expectedStatus.st_dev),
      hasNoExtendedAccessControlList(descriptor)
    else {
      throw WorkspaceFileSystemError.outcomeUncertain
    }
  }

  private static func validateRetainedDirectory(
    descriptor: Int32,
    device: dev_t,
    inode: ino_t,
    owner: uid_t
  ) throws {
    var status = stat()
    guard
      fstat(descriptor, &status) == 0,
      status.st_mode & S_IFMT == S_IFDIR,
      status.st_dev == device,
      status.st_ino == inode,
      status.st_uid == owner,
      status.st_uid == geteuid(),
      status.st_mode & mode_t(0o7777) == mode_t(0o700),
      status.st_flags == 0,
      hasNoExtendedAccessControlList(descriptor)
    else {
      throw WorkspaceFileSystemError.outcomeUncertain
    }
  }

  private static func statusIsSecureDirectory(_ status: stat, expectedDevice: dev_t) -> Bool {
    status.st_mode & S_IFMT == S_IFDIR
      && status.st_dev == expectedDevice
      && status.st_uid == geteuid()
      && status.st_mode & mode_t(0o7777) == mode_t(0o700)
      && status.st_flags == 0
  }

  private static func acquireFileLock(_ descriptor: Int32) throws {
    while flock(descriptor, LOCK_EX) != 0 {
      guard errno == EINTR else {
        throw WorkspaceFileSystemError.ioFailure
      }
    }
  }

  private static func acquireLifetimeLock(_ descriptor: Int32) -> Bool {
    while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
      if errno == EINTR {
        continue
      }
      return false
    }
    return true
  }

  private static func slotName(for index: Int) -> String {
    "runtime-slot-\(String(format: "%02d", index))"
  }

  private static func isSlotName(_ name: String, maximumSlotCount: Int) -> Bool {
    (0..<maximumSlotCount).contains { slotName(for: $0) == name }
  }

  private static func entryCount(in descriptor: Int32) throws -> Int {
    try entryNames(in: descriptor, maximumCount: maximumRetainedEntryCount).count
  }

  private static func entryNames(in descriptor: Int32, maximumCount: Int) throws -> [String] {
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

    var names: [String] = []
    while true {
      errno = 0
      guard let entry = readdir(directory) else {
        guard errno == 0 else {
          throw WorkspaceFileSystemError.ioFailure
        }
        return names
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
      guard names.count < maximumCount else {
        throw WorkspaceFileSystemError.capacityExceeded
      }
      names.append(name)
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
