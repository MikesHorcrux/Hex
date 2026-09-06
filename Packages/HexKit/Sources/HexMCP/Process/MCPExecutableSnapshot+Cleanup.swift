import Darwin

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

  static func hardenAndCloseOwnedRegularFiles(
    _ files: [MCPExecutableSnapshotOwnedFile]
  ) {
    for file in files {
      var currentStatus = stat()
      let canMutate =
        fstat(file.descriptor, &currentStatus) == 0
        && currentStatus.st_mode & S_IFMT == S_IFREG
        && currentStatus.st_uid == geteuid()
        && file.status.map { sameOwnedFileIdentity($0, currentStatus) } ?? true
      if canMutate {
        _ = ftruncate(file.descriptor, 0)
        _ = fchmod(file.descriptor, 0o000)
        _ = fsync(file.descriptor)
      }
      Darwin.close(file.descriptor)
    }
  }

  static func closeOwnedRegularFiles(
    _ files: [MCPExecutableSnapshotOwnedFile]
  ) {
    for file in files {
      Darwin.close(file.descriptor)
    }
  }

  private static func sameOwnedFileIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev
      && lhs.st_ino == rhs.st_ino
      && lhs.st_mode & S_IFMT == S_IFREG
      && rhs.st_mode & S_IFMT == S_IFREG
      && lhs.st_uid == geteuid()
      && rhs.st_uid == geteuid()
  }
}
