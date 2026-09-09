import Darwin
import Foundation

struct WorkspaceFileMetadataSnapshot {
  private static let maximumAttributeCount = 256
  private static let maximumAttributeNameBytes = 64 * 1_024
  private static let maximumMetadataBytes = 1 * 1_024 * 1_024

  let device: dev_t
  let inode: ino_t
  let mode: mode_t
  let linkCount: nlink_t
  let ownerID: uid_t
  let groupID: gid_t
  let size: off_t
  let flags: UInt32
  let generation: UInt32
  let modificationTimeSeconds: Int
  let modificationTimeNanoseconds: Int
  let changeTimeSeconds: Int
  let changeTimeNanoseconds: Int
  let birthTimeSeconds: Int
  let birthTimeNanoseconds: Int
  let extendedAttributes: [String: Data]
  let accessControlList: String?

  // Extended ACLs and non-owner-safe flags can make a rejected temporary file impossible to
  // dispose of. They are detected and rejected before commit creates that file.
  var permitsAtomicReplacement: Bool {
    // UF_TRACKED is document-ID bookkeeping, not an immutability or access restriction.
    // Preserve it on replacement just like the other owner-reapplicable flags.
    let safelyReapplicableFlags = UInt32(UF_NODUMP | UF_OPAQUE | UF_HIDDEN | UF_TRACKED)
    return accessControlList == nil && flags & ~safelyReapplicableFlags == 0
  }

  init(descriptor: Int32) throws {
    // First access to privacy-managed metadata can update ctime. Establish access before
    // taking the baseline; the actual snapshot below still requires stable status throughout.
    _ = try Self.readExtendedAttributes(from: descriptor)
    var beforeStatus = stat()
    guard
      fstat(descriptor, &beforeStatus) == 0,
      beforeStatus.st_mode & S_IFMT == S_IFREG,
      beforeStatus.st_size >= 0
    else {
      throw WorkspaceFileSystemError.ioFailure
    }
    let attributes = try Self.readExtendedAttributes(from: descriptor)
    let accessControlList = try Self.readAccessControlList(from: descriptor)
    let attributeBytes = try Self.serializedMetadataByteCount(
      attributes: attributes,
      accessControlList: accessControlList
    )
    guard attributeBytes <= Self.maximumMetadataBytes else {
      throw WorkspaceFileSystemError.capacityExceeded
    }
    var afterStatus = stat()
    guard
      fstat(descriptor, &afterStatus) == 0,
      Self.statusMatches(
        afterStatus,
        expected: beforeStatus,
        comparesChangeTime: true,
        expectedLinkCount: beforeStatus.st_nlink
      )
    else {
      throw WorkspaceFileSystemError.revisionConflict
    }

    device = afterStatus.st_dev
    inode = afterStatus.st_ino
    mode = afterStatus.st_mode
    linkCount = afterStatus.st_nlink
    ownerID = afterStatus.st_uid
    groupID = afterStatus.st_gid
    size = afterStatus.st_size
    flags = afterStatus.st_flags
    generation = afterStatus.st_gen
    modificationTimeSeconds = afterStatus.st_mtimespec.tv_sec
    modificationTimeNanoseconds = afterStatus.st_mtimespec.tv_nsec
    changeTimeSeconds = afterStatus.st_ctimespec.tv_sec
    changeTimeNanoseconds = afterStatus.st_ctimespec.tv_nsec
    birthTimeSeconds = afterStatus.st_birthtimespec.tv_sec
    birthTimeNanoseconds = afterStatus.st_birthtimespec.tv_nsec
    extendedAttributes = attributes
    self.accessControlList = accessControlList
  }

  func matches(
    _ expected: WorkspaceFileMetadataSnapshot,
    comparesChangeTime: Bool,
    expectedLinkCount: nlink_t? = nil
  ) -> Bool {
    let stableMetadataMatches =
      device == expected.device
      && inode == expected.inode
      && mode == expected.mode
      && linkCount == (expectedLinkCount ?? expected.linkCount)
      && ownerID == expected.ownerID
      && groupID == expected.groupID
      && size == expected.size
      && flags == expected.flags
      && generation == expected.generation
      && modificationTimeSeconds == expected.modificationTimeSeconds
      && modificationTimeNanoseconds == expected.modificationTimeNanoseconds
      && birthTimeSeconds == expected.birthTimeSeconds
      && birthTimeNanoseconds == expected.birthTimeNanoseconds
      && extendedAttributes == expected.extendedAttributes
      && accessControlList == expected.accessControlList
    guard stableMetadataMatches, comparesChangeTime else {
      return stableMetadataMatches
    }
    return changeTimeSeconds == expected.changeTimeSeconds
      && changeTimeNanoseconds == expected.changeTimeNanoseconds
  }

  func hasIdentity(
    of expected: WorkspaceFileMetadataSnapshot,
    expectedLinkCount: nlink_t
  ) -> Bool {
    device == expected.device
      && inode == expected.inode
      && linkCount == expectedLinkCount
  }

  func applyPreservedMetadata(to descriptor: Int32) throws {
    guard permitsAtomicReplacement else {
      throw WorkspaceFileSystemError.ioFailure
    }
    guard fchown(descriptor, ownerID, groupID) == 0 else {
      throw WorkspaceFileSystemError.ioFailure
    }
    guard fchmod(descriptor, mode & mode_t(0o7777)) == 0 else {
      throw WorkspaceFileSystemError.ioFailure
    }
    for name in extendedAttributes.keys.sorted() {
      guard let value = extendedAttributes[name] else {
        throw WorkspaceFileSystemError.ioFailure
      }
      let result = value.withUnsafeBytes { bytes in
        name.withCString { namePointer in
          fsetxattr(
            descriptor,
            namePointer,
            bytes.baseAddress,
            bytes.count,
            0,
            0
          )
        }
      }
      guard result == 0 else {
        throw WorkspaceFileSystemError.ioFailure
      }
    }
    guard fchflags(descriptor, flags) == 0 else {
      throw WorkspaceFileSystemError.ioFailure
    }

    let applied = try WorkspaceFileMetadataSnapshot(descriptor: descriptor)
    guard applied.hasPreservedMetadata(of: self) else {
      throw WorkspaceFileSystemError.ioFailure
    }
  }

  private func hasPreservedMetadata(of expected: WorkspaceFileMetadataSnapshot) -> Bool {
    mode == expected.mode
      && ownerID == expected.ownerID
      && groupID == expected.groupID
      && flags == expected.flags
      && extendedAttributes == expected.extendedAttributes
      && accessControlList == expected.accessControlList
  }

  private static func readExtendedAttributes(
    from descriptor: Int32
  ) throws -> [String: Data] {
    let nameByteCount = flistxattr(descriptor, nil, 0, 0)
    guard nameByteCount >= 0 else {
      throw WorkspaceFileSystemError.ioFailure
    }
    guard nameByteCount <= maximumAttributeNameBytes else {
      throw WorkspaceFileSystemError.capacityExceeded
    }
    guard nameByteCount > 0 else {
      return [:]
    }

    var nameBytes = [CChar](repeating: 0, count: nameByteCount)
    let copiedNameByteCount = nameBytes.withUnsafeMutableBufferPointer { buffer in
      flistxattr(descriptor, buffer.baseAddress, buffer.count, 0)
    }
    guard copiedNameByteCount == nameByteCount else {
      throw WorkspaceFileSystemError.revisionConflict
    }
    let nameData = Data(nameBytes.map { UInt8(bitPattern: $0) })
    guard nameData.last == 0 else {
      throw WorkspaceFileSystemError.ioFailure
    }
    let encodedNames = nameData.split(separator: 0, omittingEmptySubsequences: true)
    guard encodedNames.count <= maximumAttributeCount else {
      throw WorkspaceFileSystemError.capacityExceeded
    }

    var attributes: [String: Data] = [:]
    attributes.reserveCapacity(encodedNames.count)
    var aggregateByteCount = nameByteCount
    for encodedName in encodedNames {
      guard let name = String(data: Data(encodedName), encoding: .utf8) else {
        throw WorkspaceFileSystemError.ioFailure
      }
      // macOS adds or updates this access bookkeeping when a file is linked into or opened
      // inside a protected folder. Leave it intact on disk and let the OS manage it rather
      // than treating it as editable metadata to compare or copy during atomic publication.
      if name == "com.apple.macl" { continue }
      // decmpfs describes the filesystem's compression representation, not user metadata.
      // Publication can add/remove it even while logical bytes and flags remain unchanged.
      // Do not copy a prior representation onto newly written bytes or compare it as metadata;
      // content hashes, inode/status checks, and the compressed/dataless flag rejection remain.
      if name == "com.apple.decmpfs" { continue }
      let valueByteCount = name.withCString { namePointer in
        fgetxattr(descriptor, namePointer, nil, 0, 0, 0)
      }
      guard valueByteCount >= 0 else {
        if errno == ENOATTR || errno == ERANGE {
          throw WorkspaceFileSystemError.revisionConflict
        }
        throw WorkspaceFileSystemError.ioFailure
      }
      let (candidateByteCount, overflowed) = aggregateByteCount.addingReportingOverflow(
        valueByteCount
      )
      guard !overflowed, candidateByteCount <= maximumMetadataBytes else {
        throw WorkspaceFileSystemError.capacityExceeded
      }
      aggregateByteCount = candidateByteCount
      var value = Data(count: valueByteCount)
      let copiedValueByteCount = value.withUnsafeMutableBytes { bytes in
        name.withCString { namePointer in
          fgetxattr(
            descriptor,
            namePointer,
            bytes.baseAddress,
            bytes.count,
            0,
            0
          )
        }
      }
      guard copiedValueByteCount == valueByteCount, attributes[name] == nil else {
        throw WorkspaceFileSystemError.revisionConflict
      }
      attributes[name] = value
    }
    return attributes
  }

  private static func readAccessControlList(from descriptor: Int32) throws -> String? {
    errno = 0
    guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
      if errno == ENOENT {
        return nil
      }
      throw WorkspaceFileSystemError.ioFailure
    }
    defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
    var textByteCount = 0
    guard let textPointer = acl_to_text(acl, &textByteCount) else {
      throw WorkspaceFileSystemError.ioFailure
    }
    defer { _ = acl_free(UnsafeMutableRawPointer(textPointer)) }
    guard
      textByteCount >= 0,
      textByteCount <= maximumMetadataBytes,
      let text = String(validatingCString: textPointer)
    else {
      throw WorkspaceFileSystemError.capacityExceeded
    }
    return text
  }

  private static func serializedMetadataByteCount(
    attributes: [String: Data],
    accessControlList: String?
  ) throws -> Int {
    var byteCount = accessControlList?.utf8.count ?? 0
    for (name, value) in attributes {
      let (withName, nameOverflowed) = byteCount.addingReportingOverflow(name.utf8.count)
      let (withValue, valueOverflowed) = withName.addingReportingOverflow(value.count)
      guard !nameOverflowed, !valueOverflowed else {
        throw WorkspaceFileSystemError.capacityExceeded
      }
      byteCount = withValue
    }
    return byteCount
  }

  private static func statusMatches(
    _ status: stat,
    expected: stat,
    comparesChangeTime: Bool,
    expectedLinkCount: nlink_t
  ) -> Bool {
    let stableMetadataMatches =
      status.st_mode == expected.st_mode
      && status.st_dev == expected.st_dev
      && status.st_ino == expected.st_ino
      && status.st_nlink == expectedLinkCount
      && status.st_uid == expected.st_uid
      && status.st_gid == expected.st_gid
      && status.st_size == expected.st_size
      && status.st_flags == expected.st_flags
      && status.st_gen == expected.st_gen
      && status.st_mtimespec.tv_sec == expected.st_mtimespec.tv_sec
      && status.st_mtimespec.tv_nsec == expected.st_mtimespec.tv_nsec
      && status.st_birthtimespec.tv_sec == expected.st_birthtimespec.tv_sec
      && status.st_birthtimespec.tv_nsec == expected.st_birthtimespec.tv_nsec
    guard stableMetadataMatches, comparesChangeTime else {
      return stableMetadataMatches
    }
    return status.st_ctimespec.tv_sec == expected.st_ctimespec.tv_sec
      && status.st_ctimespec.tv_nsec == expected.st_ctimespec.tv_nsec
  }
}
