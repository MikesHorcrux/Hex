import Darwin

final class MCPExecutableSnapshot: Sendable {
  static let maximumExecutableBytes: off_t = 256 * 1_024 * 1_024
  static let maximumBundleBytes: off_t = off_t(
    MCPExecutableSnapshotPolicy.standard.maximumCopiedBytesPerSlot
  )
  static let maximumBundleEntries =
    MCPExecutableSnapshotPolicy.standard.maximumEntriesPerSlot
  static let maximumBundleImages = 512
  static let maximumSnapshotPathBytes = 4_096
  static let maximumSnapshotPathDepth = 64
  static let maximumSymbolicLinkBytes = 4_096
  static let maximumRunpathsPerImage = MCPMachOImage.maximumRunpathCount
  static let maximumRunpathBytesPerImage = MCPMachOImage.maximumRunpathBytes
  static let maximumClosureRunpaths = MCPMachOImage.maximumClosureRunpathCount
  static let maximumClosureRunpathBytes = MCPMachOImage.maximumClosureRunpathBytes

  let executablePath: String
  let sourcePath: String?
  let sourceStatus: stat
  let status: stat

  private let namespaceParentDescriptor: Int32
  private let namespaceBasename: String
  private let namespaceStatus: stat
  private let parentDescriptor: Int32
  private let directoryBasename: String
  private let directoryDescriptor: Int32
  private let directoryStatus: stat
  private let executableDescriptor: Int32
  private let entries: [MCPExecutableSnapshotEntry]
  private let ownedRegularFiles: [MCPExecutableSnapshotOwnedFile]

  private init(
    executablePath: String,
    sourcePath: String?,
    sourceStatus: stat,
    status: stat,
    namespaceParentDescriptor: Int32,
    namespaceBasename: String,
    namespaceStatus: stat,
    parentDescriptor: Int32,
    directoryBasename: String,
    directoryDescriptor: Int32,
    directoryStatus: stat,
    executableDescriptor: Int32,
    entries: [MCPExecutableSnapshotEntry],
    ownedRegularFiles: [MCPExecutableSnapshotOwnedFile]
  ) {
    self.executablePath = executablePath
    self.sourcePath = sourcePath
    self.sourceStatus = sourceStatus
    self.status = status
    self.namespaceParentDescriptor = namespaceParentDescriptor
    self.namespaceBasename = namespaceBasename
    self.namespaceStatus = namespaceStatus
    self.parentDescriptor = parentDescriptor
    self.directoryBasename = directoryBasename
    self.directoryDescriptor = directoryDescriptor
    self.directoryStatus = directoryStatus
    self.executableDescriptor = executableDescriptor
    self.entries = entries
    self.ownedRegularFiles = ownedRegularFiles
  }

  deinit {
    if flock(directoryDescriptor, LOCK_EX | LOCK_NB) == 0 {
      Self.hardenAndCloseOwnedRegularFiles(ownedRegularFiles)
    } else {
      Self.closeOwnedRegularFiles(ownedRegularFiles)
    }
    Darwin.close(directoryDescriptor)
    Darwin.close(parentDescriptor)
    Darwin.close(namespaceParentDescriptor)
  }

  /// Gives the spawned process an independent shared lease. If Hex exits first, a live MCP child
  /// continues blocking destructive reclamation until the child and its descendants close it.
  func makeProcessLeaseDescriptor() -> Int32 {
    guard isIntact() else { return -1 }
    let descriptor = ".".withCString { name in
      openat(
        directoryDescriptor,
        name,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
      )
    }
    guard descriptor >= 0 else { return -1 }
    var descriptorStatus = stat()
    guard
      fstat(descriptor, &descriptorStatus) == 0,
      Self.sameSnapshotDirectoryIdentityAndPermissions(
        directoryStatus,
        descriptorStatus
      ),
      flock(descriptor, LOCK_SH | LOCK_NB) == 0,
      isIntact()
    else {
      Darwin.close(descriptor)
      return -1
    }
    return descriptor
  }

  static func create(
    from sourceDescriptor: Int32,
    initialStatus: stat,
    sourcePath: String? = nil,
    afterSourceValidation: (@Sendable (_ snapshotPath: String) -> Void)?,
    policy: MCPExecutableSnapshotPolicy = .standard,
    namespaceBasename: String = MCPExecutableSnapshotAdmission.productionNamespaceBasename
  ) throws -> MCPExecutableSnapshot {
    guard isAcceptableSource(initialStatus) else {
      throw MCPClientSessionError.connectionClosed
    }

    let bundle = sourcePath.flatMap { Self.bundleLayout(for: $0) }
    let trustedXcodeBundle = bundle.flatMap { layout in
      Self.trustedSignedXcodeBundle(rootPath: layout.rootPath)
    }
    let privateDirectory = try makePrivateDirectory(
      policy: policy,
      namespaceBasename: namespaceBasename
    )
    var copyState = MCPExecutableSnapshotCopyState(
      policy: policy,
      allowsTrustedHardLinks: false
    )
    var executableDescriptor = Int32(-1)
    var completed = false
    defer {
      if !completed {
        hardenAndCloseOwnedRegularFiles(copyState.ownedRegularFiles)
        Darwin.close(privateDirectory.descriptor)
        Darwin.close(privateDirectory.parentDescriptor)
        Darwin.close(privateDirectory.namespaceParentDescriptor)
      }
    }

    let executableRelativePath: String
    let executableStatus: stat
    if let layout = bundle {
      if let trustedXcodeBundle {
        guard trustedXcodeBundle.isIntact() else {
          throw MCPClientSessionError.connectionClosed
        }
        copyState.allowsTrustedHardLinks = true
      }
      let result = try createBundleSnapshot(
        layout: layout,
        sourceDescriptor: sourceDescriptor,
        initialStatus: initialStatus,
        destination: privateDirectory,
        copyState: &copyState,
        afterSourceValidation: afterSourceValidation,
        trustedXcodeBundle: trustedXcodeBundle
      )
      executableRelativePath = layout.executableRelativePath
      executableDescriptor = result.descriptor
      executableStatus = result.status
    } else {
      let result = try copyRegularFile(
        sourceDescriptor: sourceDescriptor,
        initialStatus: initialStatus,
        sourceRelativePath: "executable",
        destinationRelativePath: "executable",
        destinationRootDescriptor: privateDirectory.descriptor,
        requireExecutable: true,
        copyState: &copyState,
        beforeCopy: {
          afterSourceValidation?(privateDirectory.path + "/executable")
        }
      )
      executableRelativePath = "executable"
      executableDescriptor = result.descriptor
      executableStatus = result.status
    }

    var finalDirectoryStatus = stat()
    guard
      fstat(privateDirectory.descriptor, &finalDirectoryStatus) == 0,
      isAcceptableSnapshotDirectory(finalDirectoryStatus),
      sameDirectoryIdentity(privateDirectory.initialStatus, finalDirectoryStatus)
    else {
      throw MCPClientSessionError.connectionClosed
    }
    let snapshotEntries = try captureSnapshotEntries(
      copyState.createdEntries,
      rootDescriptor: privateDirectory.descriptor
    )
    completed = true
    return MCPExecutableSnapshot(
      executablePath: privateDirectory.path + "/" + executableRelativePath,
      sourcePath: sourcePath,
      sourceStatus: initialStatus,
      status: executableStatus,
      namespaceParentDescriptor: privateDirectory.namespaceParentDescriptor,
      namespaceBasename: privateDirectory.namespaceBasename,
      namespaceStatus: privateDirectory.namespaceStatus,
      parentDescriptor: privateDirectory.parentDescriptor,
      directoryBasename: privateDirectory.basename,
      directoryDescriptor: privateDirectory.descriptor,
      directoryStatus: finalDirectoryStatus,
      executableDescriptor: executableDescriptor,
      entries: snapshotEntries,
      ownedRegularFiles: copyState.ownedRegularFiles
    )
  }

  func isIntact() -> Bool {
    var namespaceDescriptorStatus = stat()
    var namedNamespaceStatus = stat()
    guard
      fstat(parentDescriptor, &namespaceDescriptorStatus) == 0,
      Self.sameSnapshotDirectoryIdentityAndPermissions(
        namespaceStatus,
        namespaceDescriptorStatus
      ),
      namespaceBasename.withCString({ name in
        fstatat(
          namespaceParentDescriptor,
          name,
          &namedNamespaceStatus,
          AT_SYMLINK_NOFOLLOW
        )
      }) == 0,
      Self.sameSnapshotDirectoryIdentityAndPermissions(
        namespaceStatus,
        namedNamespaceStatus
      )
    else {
      return false
    }
    var descriptorStatus = stat()
    var namedDirectoryStatus = stat()
    guard
      fstat(directoryDescriptor, &descriptorStatus) == 0,
      Self.sameSnapshotIdentityAndMetadata(directoryStatus, descriptorStatus),
      directoryBasename.withCString({ name in
        fstatat(parentDescriptor, name, &namedDirectoryStatus, AT_SYMLINK_NOFOLLOW)
      }) == 0,
      Self.sameSnapshotIdentityAndMetadata(directoryStatus, namedDirectoryStatus)
    else {
      return false
    }
    var executableStatus = stat()
    guard
      fstat(executableDescriptor, &executableStatus) == 0,
      Self.sameSnapshotIdentityAndMetadata(status, executableStatus)
    else {
      return false
    }
    return entries.allSatisfy { entry in
      guard
        let currentStatus = Self.status(
          of: entry.created.relativePath,
          kind: entry.created.kind,
          beneath: directoryDescriptor
        )
      else {
        return false
      }
      return Self.sameSnapshotIdentityAndMetadata(entry.status, currentStatus)
    }
  }

  func sourceIsIntact(at expectedPath: String) -> Bool {
    guard sourcePath == expectedPath else { return false }
    let descriptor = Darwin.open(
      expectedPath,
      O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else { return false }
    defer { Darwin.close(descriptor) }

    var descriptorStatus = stat()
    var namedStatus = stat()
    return fstat(descriptor, &descriptorStatus) == 0
      && lstat(expectedPath, &namedStatus) == 0
      && Self.isAcceptableSource(descriptorStatus)
      && Self.sameSourceIdentityAndMetadata(sourceStatus, descriptorStatus)
      && Self.sameSourceIdentityAndMetadata(sourceStatus, namedStatus)
  }

  static func isAcceptableSource(_ status: stat) -> Bool {
    let effectiveUserID = geteuid()
    return status.st_mode & S_IFMT == S_IFREG
      && (status.st_uid == 0 || status.st_uid == effectiveUserID)
      && status.st_nlink == 1
      && status.st_size > 0
      && status.st_size <= maximumExecutableBytes
      && hasExecutionPermission(status, effectiveUserID: effectiveUserID)
      && status.st_mode & (S_ISUID | S_ISGID) == 0
      && status.st_mode & (S_IWGRP | S_IWOTH) == 0
  }

}
