import Darwin
import Foundation

extension MCPExecutableSnapshot {
  static func captureSnapshotEntries(
    _ createdEntries: [CreatedEntry],
    rootDescriptor: Int32
  ) throws -> [SnapshotEntry] {
    try createdEntries.map { created in
      guard
        let currentStatus = status(
          of: created.relativePath,
          kind: created.kind,
          beneath: rootDescriptor
        ),
        sameCreatedEntryIdentity(created.status, currentStatus, kind: created.kind)
      else {
        throw MCPClientSessionError.connectionClosed
      }
      return SnapshotEntry(created: created, status: currentStatus)
    }
  }

  static func status(
    of relativePath: String,
    kind: CreatedEntry.Kind,
    beneath rootDescriptor: Int32
  ) -> stat? {
    guard let normalized = normalizeRelativePath(relativePath, relativeTo: ""),
      normalized == relativePath,
      let basename = normalized.split(separator: "/").last.map(String.init),
      let parent = openSnapshotDirectory(
        directoryPath(of: normalized),
        beneath: rootDescriptor
      )
    else {
      return nil
    }
    defer { Darwin.close(parent) }
    var currentStatus = stat()
    let result = basename.withCString { name in
      fstatat(parent, name, &currentStatus, AT_SYMLINK_NOFOLLOW)
    }
    guard result == 0 else { return nil }
    let expectedType: mode_t
    switch kind {
    case .directory: expectedType = S_IFDIR
    case .file: expectedType = S_IFREG
    case .symbolicLink: expectedType = S_IFLNK
    }
    guard currentStatus.st_mode & S_IFMT == expectedType,
      currentStatus.st_uid == geteuid()
    else {
      return nil
    }
    if kind == .directory, !isAcceptableSnapshotDirectory(currentStatus) { return nil }
    if kind == .file,
      currentStatus.st_nlink != 1
        || currentStatus.st_mode & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID) != 0
    {
      return nil
    }
    return currentStatus
  }

  static func removeCreatedEntries(
    _ entries: [CreatedEntry],
    from rootDescriptor: Int32,
    auditHooks: CleanupAuditHooks? = nil
  ) {
    let ordered = entries.sorted { lhs, rhs in
      let lhsDepth = lhs.relativePath.split(separator: "/").count
      let rhsDepth = rhs.relativePath.split(separator: "/").count
      if lhsDepth != rhsDepth { return lhsDepth > rhsDepth }
      let lhsDirectoryRank = lhs.kind == .directory ? 1 : 0
      let rhsDirectoryRank = rhs.kind == .directory ? 1 : 0
      if lhsDirectoryRank != rhsDirectoryRank {
        return lhsDirectoryRank < rhsDirectoryRank
      }
      return lhs.relativePath > rhs.relativePath
    }
    for entry in ordered {
      guard let normalized = normalizeRelativePath(entry.relativePath, relativeTo: ""),
        normalized == entry.relativePath,
        let basename = normalized.split(separator: "/").last.map(String.init),
        let parent = openSnapshotDirectory(
          directoryPath(of: normalized),
          beneath: rootDescriptor
        )
      else {
        continue
      }
      var currentStatus = stat()
      let statusResult = basename.withCString { name in
        fstatat(parent, name, &currentStatus, AT_SYMLINK_NOFOLLOW)
      }
      guard statusResult == 0,
        sameCreatedEntryIdentity(entry.status, currentStatus, kind: entry.kind)
      else {
        Darwin.close(parent)
        continue
      }
      auditHooks?.afterEntryIdentityValidation?(parent, basename)
      quarantineAndRemove(
        parentDescriptor: parent,
        basename: basename,
        removalFlags: entry.kind == .directory ? AT_REMOVEDIR : 0,
        identityMatches: {
          sameCreatedEntryIdentity(entry.status, $0, kind: entry.kind)
        },
        afterQuarantinedIdentityValidation:
          auditHooks?.afterQuarantinedEntryIdentityValidation
      )
      Darwin.close(parent)
    }
  }

  static func removePrivateDirectory(
    parentDescriptor: Int32,
    basename: String,
    directoryStatus: stat,
    auditHooks: CleanupAuditHooks? = nil
  ) {
    var namedStatus = stat()
    let statusResult = basename.withCString { name in
      fstatat(parentDescriptor, name, &namedStatus, AT_SYMLINK_NOFOLLOW)
    }
    guard
      statusResult == 0,
      sameDirectoryIdentity(directoryStatus, namedStatus)
    else {
      return
    }
    auditHooks?.afterRootIdentityValidation?(parentDescriptor, basename)
    quarantineAndRemove(
      parentDescriptor: parentDescriptor,
      basename: basename,
      removalFlags: AT_REMOVEDIR,
      identityMatches: { sameDirectoryIdentity(directoryStatus, $0) },
      afterQuarantinedIdentityValidation:
        auditHooks?.afterQuarantinedRootIdentityValidation
    )
  }

  private static func quarantineAndRemove(
    parentDescriptor: Int32,
    basename: String,
    removalFlags: Int32,
    identityMatches: (stat) -> Bool,
    afterQuarantinedIdentityValidation:
      (@Sendable (_ parentDescriptor: Int32, _ basename: String) -> Void)?
  ) {
    var quarantineBasename: String?
    for _ in 0..<8 {
      let candidate = ".hex-mcp-cleanup.\(UUID().uuidString)"
      let result = candidate.withCString { quarantineName in
        basename.withCString { name in
          renameatx_np(
            parentDescriptor,
            name,
            parentDescriptor,
            quarantineName,
            UInt32(RENAME_EXCL)
          )
        }
      }
      if result == 0 {
        quarantineBasename = candidate
        break
      }
      if errno != EEXIST { return }
    }
    guard let quarantineBasename else { return }

    var quarantinedStatus = stat()
    let statusResult = quarantineBasename.withCString { name in
      fstatat(parentDescriptor, name, &quarantinedStatus, AT_SYMLINK_NOFOLLOW)
    }
    guard statusResult == 0, identityMatches(quarantinedStatus) else {
      restoreQuarantinedEntry(
        parentDescriptor: parentDescriptor,
        quarantineBasename: quarantineBasename,
        originalBasename: basename
      )
      return
    }

    if let afterQuarantinedIdentityValidation {
      afterQuarantinedIdentityValidation(parentDescriptor, quarantineBasename)
      // Darwin exposes no compare-and-unlink operation. Once adversarial audit code has
      // run in the final name-based window, retain whichever object occupies the
      // quarantine name instead of risking deletion of an unrelated replacement.
      restoreQuarantinedEntry(
        parentDescriptor: parentDescriptor,
        quarantineBasename: quarantineBasename,
        originalBasename: basename
      )
      return
    }

    let removalResult = quarantineBasename.withCString { name in
      unlinkat(parentDescriptor, name, removalFlags)
    }
    if removalResult != 0 {
      restoreQuarantinedEntry(
        parentDescriptor: parentDescriptor,
        quarantineBasename: quarantineBasename,
        originalBasename: basename
      )
    }
  }

  private static func restoreQuarantinedEntry(
    parentDescriptor: Int32,
    quarantineBasename: String,
    originalBasename: String
  ) {
    _ = originalBasename.withCString { originalName in
      quarantineBasename.withCString { quarantineName in
        renameatx_np(
          parentDescriptor,
          quarantineName,
          parentDescriptor,
          originalName,
          UInt32(RENAME_EXCL)
        )
      }
    }
  }
}
