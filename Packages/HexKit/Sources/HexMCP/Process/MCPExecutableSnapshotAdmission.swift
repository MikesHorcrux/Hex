import Darwin

enum MCPExecutableSnapshotAdmission {
  /// Version two adds descriptor-backed slot leases and persistent inode identities. Keeping a
  /// distinct namespace prevents a pre-lease slot from being mistaken for safely reclaimable data.
  static let productionNamespaceBasename = ".hex-mcp-snapshots.v2"

  static func claimSlot(
    policy: MCPExecutableSnapshotPolicy,
    namespaceBasename: String = productionNamespaceBasename,
    openClaimedSlot: @Sendable (Int32, String) -> Int32 = openDirectoryForProduction
  ) throws -> MCPExecutableSnapshotPrivateDirectory {
    guard
      !namespaceBasename.isEmpty,
      namespaceBasename.utf8.count <= 255,
      !namespaceBasename.contains("/"),
      !namespaceBasename.contains("\0")
    else {
      throw MCPClientSessionError.connectionClosed
    }
    let temporaryDescriptor = Darwin.open(
      "/private/tmp",
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard temporaryDescriptor >= 0 else {
      throw MCPClientSessionError.connectionClosed
    }
    var temporaryStatus = stat()
    guard
      fstat(temporaryDescriptor, &temporaryStatus) == 0,
      temporaryStatus.st_mode & S_IFMT == S_IFDIR,
      temporaryStatus.st_uid == 0,
      temporaryStatus.st_mode & S_ISVTX != 0
    else {
      Darwin.close(temporaryDescriptor)
      throw MCPClientSessionError.connectionClosed
    }

    let createNamespaceResult = namespaceBasename.withCString { name in
      mkdirat(temporaryDescriptor, name, 0o700)
    }
    guard createNamespaceResult == 0 || errno == EEXIST else {
      Darwin.close(temporaryDescriptor)
      throw MCPClientSessionError.connectionClosed
    }
    let namespaceDescriptor = namespaceBasename.withCString { name in
      openat(
        temporaryDescriptor,
        name,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
      )
    }
    guard namespaceDescriptor >= 0 else {
      Darwin.close(temporaryDescriptor)
      throw MCPClientSessionError.connectionClosed
    }
    var transfersNamespaceDescriptors = false
    defer {
      if !transfersNamespaceDescriptors {
        Darwin.close(namespaceDescriptor)
        Darwin.close(temporaryDescriptor)
      }
    }
    var namespaceStatus = stat()
    var namedNamespaceStatus = stat()
    let namedNamespaceResult = namespaceBasename.withCString { name in
      fstatat(temporaryDescriptor, name, &namedNamespaceStatus, AT_SYMLINK_NOFOLLOW)
    }
    guard
      fstat(namespaceDescriptor, &namespaceStatus) == 0,
      namedNamespaceResult == 0,
      MCPExecutableSnapshot.isAcceptableSnapshotDirectory(namespaceStatus),
      namespaceStatus.st_mode & 0o777 == 0o700,
      MCPExecutableSnapshot.sameSnapshotDirectoryIdentityAndPermissions(
        namespaceStatus,
        namedNamespaceStatus
      )
    else {
      throw MCPClientSessionError.connectionClosed
    }

    for index in 0..<policy.maximumRetainedSlots {
      let slotBasename = slotBasename(index)
      guard
        let claimedSlot = try claimPreparedSlot(
          index: index,
          basename: slotBasename,
          namespaceDescriptor: namespaceDescriptor,
          policy: policy,
          openClaimedSlot: openClaimedSlot
        )
      else {
        continue
      }
      var finalNamespaceStatus = stat()
      var finalNamedNamespaceStatus = stat()
      let finalNamedNamespaceResult = namespaceBasename.withCString { name in
        fstatat(
          temporaryDescriptor,
          name,
          &finalNamedNamespaceStatus,
          AT_SYMLINK_NOFOLLOW
        )
      }
      guard
        fstat(namespaceDescriptor, &finalNamespaceStatus) == 0,
        finalNamedNamespaceResult == 0,
        MCPExecutableSnapshot.sameSnapshotDirectoryIdentityAndPermissions(
          namespaceStatus,
          finalNamespaceStatus
        ),
        MCPExecutableSnapshot.sameSnapshotDirectoryIdentityAndPermissions(
          finalNamespaceStatus,
          finalNamedNamespaceStatus
        )
      else {
        Darwin.close(claimedSlot.descriptor)
        throw MCPClientSessionError.connectionClosed
      }
      transfersNamespaceDescriptors = true
      return MCPExecutableSnapshotPrivateDirectory(
        namespaceParentDescriptor: temporaryDescriptor,
        namespaceBasename: namespaceBasename,
        namespaceStatus: finalNamespaceStatus,
        parentDescriptor: namespaceDescriptor,
        basename: slotBasename,
        path: "/private/tmp/\(namespaceBasename)/\(slotBasename)",
        descriptor: claimedSlot.descriptor,
        initialStatus: claimedSlot.status
      )
    }

    throw MCPExecutableSnapshotAdmissionError.namespaceExhausted(
      MCPExecutableSnapshotNamespaceUsage(
        namespacePath: "/private/tmp/\(namespaceBasename)",
        retainedSlotCount: policy.maximumRetainedSlots,
        policy: policy
      )
    )
  }

  static func slotBasename(_ index: Int) -> String {
    let digits = String(index)
    return "slot-" + String(repeating: "0", count: max(0, 4 - digits.count)) + digits
  }

  static func openDirectoryForProduction(
    parentDescriptor: Int32,
    basename: String
  ) -> Int32 {
    basename.withCString { name in
      openat(
        parentDescriptor,
        name,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
      )
    }
  }
}
