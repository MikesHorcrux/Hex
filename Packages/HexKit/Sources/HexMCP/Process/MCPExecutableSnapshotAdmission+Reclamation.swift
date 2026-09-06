import Darwin

extension MCPExecutableSnapshotAdmission {
  static func slotIsEmpty(_ descriptor: Int32) throws -> Bool {
    try MCPExecutableSnapshot.directoryEntryNames(descriptor).isEmpty
  }

  static func reclaimSlotContents(
    _ descriptor: Int32,
    policy: MCPExecutableSnapshotPolicy
  ) throws {
    var remainingEntryCount = policy.maximumEntriesPerSlot
    var remainingPathMetadataBytes = policy.maximumPathMetadataBytesPerSlot
    var remainingCopiedBytes = policy.maximumCopiedBytesPerSlot
    try removeContents(
      beneath: descriptor,
      depth: 0,
      parentPathByteCount: 0,
      remainingEntryCount: &remainingEntryCount,
      remainingPathMetadataBytes: &remainingPathMetadataBytes,
      remainingCopiedBytes: &remainingCopiedBytes
    )
    guard try slotIsEmpty(descriptor), fsync(descriptor) == 0 else {
      throw MCPClientSessionError.connectionClosed
    }
  }

  private static func removeContents(
    beneath descriptor: Int32,
    depth: Int,
    parentPathByteCount: Int64,
    remainingEntryCount: inout Int,
    remainingPathMetadataBytes: inout Int64,
    remainingCopiedBytes: inout Int64
  ) throws {
    guard depth <= MCPExecutableSnapshot.maximumSnapshotPathDepth else {
      throw MCPClientSessionError.limitExceeded
    }
    let names = try MCPExecutableSnapshot.directoryEntryNames(descriptor)
    guard names.count <= remainingEntryCount else {
      throw MCPClientSessionError.limitExceeded
    }
    remainingEntryCount -= names.count

    for name in names {
      let separatorByteCount = parentPathByteCount == 0 ? Int64(0) : Int64(1)
      let (childPathByteCount, pathOverflowed) =
        parentPathByteCount
        .addingReportingOverflow(separatorByteCount + Int64(name.utf8.count))
      let (pathMetadataByteCount, metadataOverflowed) =
        childPathByteCount
        .addingReportingOverflow(1)
      guard
        !pathOverflowed,
        !metadataOverflowed,
        pathMetadataByteCount <= remainingPathMetadataBytes
      else {
        throw MCPClientSessionError.limitExceeded
      }
      remainingPathMetadataBytes -= pathMetadataByteCount
      var initialStatus = stat()
      let statusResult = name.withCString { childName in
        fstatat(descriptor, childName, &initialStatus, AT_SYMLINK_NOFOLLOW)
      }
      guard statusResult == 0, initialStatus.st_uid == geteuid() else {
        throw MCPClientSessionError.connectionClosed
      }

      switch initialStatus.st_mode & S_IFMT {
      case S_IFDIR:
        try removeDirectory(
          name,
          initialStatus: initialStatus,
          parentDescriptor: descriptor,
          depth: depth,
          pathByteCount: childPathByteCount,
          remainingEntryCount: &remainingEntryCount,
          remainingPathMetadataBytes: &remainingPathMetadataBytes,
          remainingCopiedBytes: &remainingCopiedBytes
        )
      case S_IFREG:
        guard
          initialStatus.st_nlink == 1,
          initialStatus.st_size >= 0,
          initialStatus.st_mode & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID) == 0
        else {
          throw MCPClientSessionError.connectionClosed
        }
        guard initialStatus.st_size <= off_t(remainingCopiedBytes) else {
          throw MCPClientSessionError.limitExceeded
        }
        guard
          name.withCString({ childName in
            unlinkat(descriptor, childName, 0)
          }) == 0
        else {
          throw MCPClientSessionError.connectionClosed
        }
        remainingCopiedBytes -= Int64(initialStatus.st_size)
      case S_IFLNK:
        guard
          initialStatus.st_nlink == 1,
          initialStatus.st_size >= 0,
          initialStatus.st_size <= off_t(MCPExecutableSnapshot.maximumSymbolicLinkBytes)
        else {
          throw MCPClientSessionError.connectionClosed
        }
        guard initialStatus.st_size <= off_t(remainingPathMetadataBytes) else {
          throw MCPClientSessionError.limitExceeded
        }
        guard
          name.withCString({ childName in
            unlinkat(descriptor, childName, 0)
          }) == 0
        else {
          throw MCPClientSessionError.connectionClosed
        }
        remainingPathMetadataBytes -= Int64(initialStatus.st_size)
      default:
        throw MCPClientSessionError.connectionClosed
      }
    }
  }

  private static func removeDirectory(
    _ name: String,
    initialStatus: stat,
    parentDescriptor: Int32,
    depth: Int,
    pathByteCount: Int64,
    remainingEntryCount: inout Int,
    remainingPathMetadataBytes: inout Int64,
    remainingCopiedBytes: inout Int64
  ) throws {
    guard
      MCPExecutableSnapshot.isAcceptableSnapshotDirectory(initialStatus),
      initialStatus.st_mode & 0o777 == 0o700
    else {
      throw MCPClientSessionError.connectionClosed
    }
    let descriptor = name.withCString { childName in
      openat(
        parentDescriptor,
        childName,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
      )
    }
    guard descriptor >= 0 else {
      throw MCPClientSessionError.connectionClosed
    }
    defer { Darwin.close(descriptor) }
    var openedStatus = stat()
    guard
      fstat(descriptor, &openedStatus) == 0,
      MCPExecutableSnapshot.sameSnapshotDirectoryIdentityAndPermissions(
        initialStatus,
        openedStatus
      )
    else {
      throw MCPClientSessionError.connectionClosed
    }

    try removeContents(
      beneath: descriptor,
      depth: depth + 1,
      parentPathByteCount: pathByteCount,
      remainingEntryCount: &remainingEntryCount,
      remainingPathMetadataBytes: &remainingPathMetadataBytes,
      remainingCopiedBytes: &remainingCopiedBytes
    )

    var finalDescriptorStatus = stat()
    var finalNamedStatus = stat()
    let namedStatusResult = name.withCString { childName in
      fstatat(parentDescriptor, childName, &finalNamedStatus, AT_SYMLINK_NOFOLLOW)
    }
    guard
      try slotIsEmpty(descriptor),
      fstat(descriptor, &finalDescriptorStatus) == 0,
      namedStatusResult == 0,
      MCPExecutableSnapshot.sameSnapshotDirectoryIdentityAndPermissions(
        openedStatus,
        finalDescriptorStatus
      ),
      MCPExecutableSnapshot.sameSnapshotDirectoryIdentityAndPermissions(
        finalDescriptorStatus,
        finalNamedStatus
      ),
      name.withCString({ childName in
        unlinkat(parentDescriptor, childName, AT_REMOVEDIR)
      }) == 0
    else {
      throw MCPClientSessionError.connectionClosed
    }
  }
}
