import Darwin
import Foundation

extension MCPExecutableSnapshotAdmission {
  static func claimPreparedSlot(
    index: Int,
    basename: String,
    namespaceDescriptor: Int32,
    policy: MCPExecutableSnapshotPolicy,
    openClaimedSlot: @Sendable (Int32, String) -> Int32
  ) throws -> (descriptor: Int32, status: stat)? {
    let createResult = basename.withCString { name in
      mkdirat(namespaceDescriptor, name, 0o700)
    }
    guard createResult == 0 || errno == EEXIST else {
      throw MCPClientSessionError.connectionClosed
    }
    let slotWasCreated = createResult == 0

    let slotDescriptor = openClaimedSlot(namespaceDescriptor, basename)
    guard slotDescriptor >= 0 else {
      throw MCPClientSessionError.connectionClosed
    }
    var preserveDescriptor = false
    defer {
      if !preserveDescriptor {
        Darwin.close(slotDescriptor)
      }
    }

    guard
      let initialStatus = validatedSlotStatus(
        descriptor: slotDescriptor,
        basename: basename,
        namespaceDescriptor: namespaceDescriptor
      )
    else {
      throw MCPClientSessionError.connectionClosed
    }

    guard flock(slotDescriptor, LOCK_EX | LOCK_NB) == 0 else {
      let lockError = errno
      if lockError == EWOULDBLOCK || lockError == EAGAIN {
        return nil
      }
      throw MCPClientSessionError.connectionClosed
    }
    guard
      let lockedStatus = validatedSlotStatus(
        descriptor: slotDescriptor,
        basename: basename,
        namespaceDescriptor: namespaceDescriptor
      ),
      MCPExecutableSnapshot.sameSnapshotDirectoryIdentityAndPermissions(
        initialStatus,
        lockedStatus
      )
    else {
      throw MCPClientSessionError.connectionClosed
    }

    guard
      try preparePersistentIdentity(
        index: index,
        slotDescriptor: slotDescriptor,
        slotStatus: lockedStatus,
        slotWasCreated: slotWasCreated,
        namespaceDescriptor: namespaceDescriptor
      )
    else {
      return nil
    }
    do {
      try reclaimSlotContents(
        slotDescriptor,
        policy: policy
      )
    } catch MCPClientSessionError.limitExceeded {
      // A slot safely created under a larger valid policy can exceed this caller's cleanup
      // budget. Leave it locked until this descriptor closes and continue scanning later slots.
      return nil
    }

    guard
      let finalStatus = validatedSlotStatus(
        descriptor: slotDescriptor,
        basename: basename,
        namespaceDescriptor: namespaceDescriptor
      ),
      MCPExecutableSnapshot.sameSnapshotDirectoryIdentityAndPermissions(
        lockedStatus,
        finalStatus
      ),
      try persistentIdentityMatches(
        index: index,
        slotStatus: finalStatus,
        namespaceDescriptor: namespaceDescriptor
      )
    else {
      throw MCPClientSessionError.connectionClosed
    }
    guard flock(slotDescriptor, LOCK_SH | LOCK_NB) == 0 else {
      throw MCPClientSessionError.connectionClosed
    }

    preserveDescriptor = true
    return (slotDescriptor, finalStatus)
  }

  private static func validatedSlotStatus(
    descriptor: Int32,
    basename: String,
    namespaceDescriptor: Int32
  ) -> stat? {
    var descriptorStatus = stat()
    var namedStatus = stat()
    let namedResult = basename.withCString { name in
      fstatat(namespaceDescriptor, name, &namedStatus, AT_SYMLINK_NOFOLLOW)
    }
    guard
      fstat(descriptor, &descriptorStatus) == 0,
      namedResult == 0,
      MCPExecutableSnapshot.isAcceptableSnapshotDirectory(descriptorStatus),
      descriptorStatus.st_mode & 0o777 == 0o700,
      MCPExecutableSnapshot.sameSnapshotDirectoryIdentityAndPermissions(
        descriptorStatus,
        namedStatus
      )
    else {
      return nil
    }
    return descriptorStatus
  }

  private static func preparePersistentIdentity(
    index: Int,
    slotDescriptor: Int32,
    slotStatus: stat,
    slotWasCreated: Bool,
    namespaceDescriptor: Int32
  ) throws -> Bool {
    let identityBasename = slotIdentityBasename(index)
    var identityDescriptor = openIdentityFile(
      identityBasename,
      namespaceDescriptor: namespaceDescriptor,
      createIfMissing: false
    )
    if identityDescriptor < 0, errno == ENOENT {
      identityDescriptor = openIdentityFile(
        identityBasename,
        namespaceDescriptor: namespaceDescriptor,
        createIfMissing: true
      )
      if identityDescriptor < 0, errno == EEXIST {
        identityDescriptor = openIdentityFile(
          identityBasename,
          namespaceDescriptor: namespaceDescriptor,
          createIfMissing: false
        )
      }
    }
    guard identityDescriptor >= 0 else {
      throw MCPClientSessionError.connectionClosed
    }
    defer { Darwin.close(identityDescriptor) }

    guard
      let identityStatus = validatedIdentityStatus(
        descriptor: identityDescriptor,
        basename: identityBasename,
        namespaceDescriptor: namespaceDescriptor
      )
    else {
      throw MCPClientSessionError.connectionClosed
    }
    let expectedIdentity = slotIdentityData(slotStatus)
    let existingIdentity = try readIdentity(
      descriptor: identityDescriptor,
      status: identityStatus
    )
    if existingIdentity != expectedIdentity {
      guard slotWasCreated || !isCompleteSlotIdentity(existingIdentity) else {
        return false
      }
      guard try slotIsEmpty(slotDescriptor) else {
        return false
      }
      try writeIdentity(expectedIdentity, descriptor: identityDescriptor)
      guard fsync(namespaceDescriptor) == 0 else {
        throw MCPClientSessionError.connectionClosed
      }
    }

    guard
      let finalIdentityStatus = validatedIdentityStatus(
        descriptor: identityDescriptor,
        basename: identityBasename,
        namespaceDescriptor: namespaceDescriptor
      ),
      try readIdentity(
        descriptor: identityDescriptor,
        status: finalIdentityStatus
      ) == expectedIdentity
    else {
      throw MCPClientSessionError.connectionClosed
    }
    return true
  }

  private static func persistentIdentityMatches(
    index: Int,
    slotStatus: stat,
    namespaceDescriptor: Int32
  ) throws -> Bool {
    let identityBasename = slotIdentityBasename(index)
    let descriptor = openIdentityFile(
      identityBasename,
      namespaceDescriptor: namespaceDescriptor,
      createIfMissing: false
    )
    guard descriptor >= 0 else { return false }
    defer { Darwin.close(descriptor) }
    guard
      let status = validatedIdentityStatus(
        descriptor: descriptor,
        basename: identityBasename,
        namespaceDescriptor: namespaceDescriptor
      )
    else {
      return false
    }
    return try readIdentity(descriptor: descriptor, status: status)
      == slotIdentityData(slotStatus)
  }

  private static func openIdentityFile(
    _ basename: String,
    namespaceDescriptor: Int32,
    createIfMissing: Bool
  ) -> Int32 {
    let flags = O_RDWR | O_NOFOLLOW | O_CLOEXEC | (createIfMissing ? O_CREAT | O_EXCL : 0)
    return basename.withCString { name in
      openat(namespaceDescriptor, name, flags, 0o600)
    }
  }

  private static func validatedIdentityStatus(
    descriptor: Int32,
    basename: String,
    namespaceDescriptor: Int32
  ) -> stat? {
    var descriptorStatus = stat()
    var namedStatus = stat()
    let namedResult = basename.withCString { name in
      fstatat(namespaceDescriptor, name, &namedStatus, AT_SYMLINK_NOFOLLOW)
    }
    guard
      fstat(descriptor, &descriptorStatus) == 0,
      namedResult == 0,
      descriptorStatus.st_dev == namedStatus.st_dev,
      descriptorStatus.st_ino == namedStatus.st_ino,
      descriptorStatus.st_mode == namedStatus.st_mode,
      descriptorStatus.st_mode & S_IFMT == S_IFREG,
      descriptorStatus.st_uid == geteuid(),
      namedStatus.st_uid == geteuid(),
      descriptorStatus.st_nlink == 1,
      namedStatus.st_nlink == 1,
      descriptorStatus.st_mode & 0o777 == 0o600,
      descriptorStatus.st_size >= 0,
      descriptorStatus.st_size <= 128,
      descriptorStatus.st_size == namedStatus.st_size
    else {
      return nil
    }
    return descriptorStatus
  }

  private static func readIdentity(
    descriptor: Int32,
    status: stat
  ) throws -> Data {
    let byteCount = Int(status.st_size)
    var bytes = [UInt8](repeating: 0, count: byteCount)
    let readCount = bytes.withUnsafeMutableBytes { buffer in
      pread(descriptor, buffer.baseAddress, byteCount, 0)
    }
    guard readCount == byteCount else {
      throw MCPClientSessionError.connectionClosed
    }
    return Data(bytes)
  }

  private static func writeIdentity(
    _ identity: Data,
    descriptor: Int32
  ) throws {
    guard identity.count <= 128, ftruncate(descriptor, 0) == 0 else {
      throw MCPClientSessionError.connectionClosed
    }
    var writtenByteCount = 0
    while writtenByteCount < identity.count {
      let result = identity.withUnsafeBytes { buffer in
        pwrite(
          descriptor,
          buffer.baseAddress?.advanced(by: writtenByteCount),
          identity.count - writtenByteCount,
          off_t(writtenByteCount)
        )
      }
      if result < 0, errno == EINTR { continue }
      guard result > 0 else {
        throw MCPClientSessionError.connectionClosed
      }
      writtenByteCount += result
    }
    guard fsync(descriptor) == 0 else {
      throw MCPClientSessionError.connectionClosed
    }
  }

  private static func slotIdentityData(_ status: stat) -> Data {
    Data("hex-mcp-snapshot-slot-v1:\(status.st_dev):\(status.st_ino)\n".utf8)
  }

  private static func isCompleteSlotIdentity(_ identity: Data) -> Bool {
    guard
      let value = String(data: identity, encoding: .utf8),
      value.hasPrefix("hex-mcp-snapshot-slot-v1:"),
      value.hasSuffix("\n")
    else {
      return false
    }
    let fields = value.dropLast().split(separator: ":", omittingEmptySubsequences: false)
    return fields.count == 3
      && fields[0] == "hex-mcp-snapshot-slot-v1"
      && Int64(fields[1]) != nil
      && UInt64(fields[2]) != nil
  }

  private static func slotIdentityBasename(_ index: Int) -> String {
    ".\(slotBasename(index)).identity-v1"
  }
}
