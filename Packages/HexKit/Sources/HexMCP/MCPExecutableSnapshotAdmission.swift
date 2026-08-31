import Darwin

enum MCPExecutableSnapshotAdmission {
  static let productionNamespaceBasename = ".hex-mcp-snapshots.v1"

  static func claimSlot(
    policy: MCPExecutableSnapshotPolicy,
    namespaceBasename: String = productionNamespaceBasename,
    openClaimedSlot: @Sendable (Int32, String) -> Int32 = openDirectoryForProduction
  ) throws -> MCPExecutableSnapshot.PrivateDirectory {
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
      Darwin.close(namespaceDescriptor)
      Darwin.close(temporaryDescriptor)
      throw MCPClientSessionError.connectionClosed
    }

    for index in 0..<policy.maximumRetainedSlots {
      let slotBasename = slotBasename(index)
      let createResult = slotBasename.withCString { name in
        mkdirat(namespaceDescriptor, name, 0o700)
      }
      if createResult != 0 {
        if errno == EEXIST { continue }
        Darwin.close(namespaceDescriptor)
        Darwin.close(temporaryDescriptor)
        throw MCPClientSessionError.connectionClosed
      }
      let slotDescriptor = openClaimedSlot(namespaceDescriptor, slotBasename)
      guard slotDescriptor >= 0 else {
        Darwin.close(namespaceDescriptor)
        Darwin.close(temporaryDescriptor)
        throw MCPClientSessionError.connectionClosed
      }
      var slotStatus = stat()
      var namedSlotStatus = stat()
      let namedSlotResult = slotBasename.withCString { name in
        fstatat(namespaceDescriptor, name, &namedSlotStatus, AT_SYMLINK_NOFOLLOW)
      }
      guard
        fstat(slotDescriptor, &slotStatus) == 0,
        namedSlotResult == 0,
        MCPExecutableSnapshot.isAcceptableSnapshotDirectory(slotStatus),
        slotStatus.st_mode & 0o777 == 0o700,
        MCPExecutableSnapshot.sameSnapshotDirectoryIdentityAndPermissions(
          slotStatus,
          namedSlotStatus
        )
      else {
        Darwin.close(slotDescriptor)
        Darwin.close(namespaceDescriptor)
        Darwin.close(temporaryDescriptor)
        throw MCPClientSessionError.connectionClosed
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
        Darwin.close(slotDescriptor)
        Darwin.close(namespaceDescriptor)
        Darwin.close(temporaryDescriptor)
        throw MCPClientSessionError.connectionClosed
      }
      return MCPExecutableSnapshot.PrivateDirectory(
        namespaceParentDescriptor: temporaryDescriptor,
        namespaceBasename: namespaceBasename,
        namespaceStatus: finalNamespaceStatus,
        parentDescriptor: namespaceDescriptor,
        basename: slotBasename,
        path: "/private/tmp/\(namespaceBasename)/\(slotBasename)",
        descriptor: slotDescriptor,
        initialStatus: slotStatus
      )
    }

    Darwin.close(namespaceDescriptor)
    Darwin.close(temporaryDescriptor)
    throw MCPExecutableSnapshotAdmissionError.namespaceExhausted(
      MCPExecutableSnapshotNamespaceUsage(
        namespacePath: "/private/tmp/\(namespaceBasename)",
        retainedSlotCount: policy.maximumRetainedSlots,
        policy: policy
      )
    )
  }

  private static func slotBasename(_ index: Int) -> String {
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
