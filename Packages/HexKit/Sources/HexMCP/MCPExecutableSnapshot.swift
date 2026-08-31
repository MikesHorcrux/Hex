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
  let status: stat

  private let namespaceParentDescriptor: Int32
  private let namespaceBasename: String
  private let namespaceStatus: stat
  private let parentDescriptor: Int32
  private let directoryBasename: String
  private let directoryDescriptor: Int32
  private let directoryStatus: stat
  private let executableDescriptor: Int32
  private let entries: [SnapshotEntry]
  private let ownedRegularFiles: [MCPExecutableSnapshotOwnedFile]

  private init(
    executablePath: String,
    status: stat,
    namespaceParentDescriptor: Int32,
    namespaceBasename: String,
    namespaceStatus: stat,
    parentDescriptor: Int32,
    directoryBasename: String,
    directoryDescriptor: Int32,
    directoryStatus: stat,
    executableDescriptor: Int32,
    entries: [SnapshotEntry],
    ownedRegularFiles: [MCPExecutableSnapshotOwnedFile]
  ) {
    self.executablePath = executablePath
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
    Self.hardenAndCloseOwnedRegularFiles(ownedRegularFiles)
    Darwin.close(directoryDescriptor)
    Darwin.close(parentDescriptor)
    Darwin.close(namespaceParentDescriptor)
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
    let allowsTrustedHardLinks =
      bundle.map { layout in
        Self.isTrustedSignedXcodeBundle(rootPath: layout.rootPath)
      } ?? false
    let privateDirectory = try makePrivateDirectory(
      policy: policy,
      namespaceBasename: namespaceBasename
    )
    var copyState = CopyState(
      policy: policy,
      allowsTrustedHardLinks: allowsTrustedHardLinks
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
      let result = try createBundleSnapshot(
        layout: layout,
        sourceDescriptor: sourceDescriptor,
        initialStatus: initialStatus,
        destination: privateDirectory,
        copyState: &copyState,
        afterSourceValidation: afterSourceValidation
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

  struct PrivateDirectory {
    let namespaceParentDescriptor: Int32
    let namespaceBasename: String
    let namespaceStatus: stat
    let parentDescriptor: Int32
    let basename: String
    let path: String
    let descriptor: Int32
    let initialStatus: stat
  }

  struct BundleLayout {
    let rootPath: String
    let executableRelativePath: String
  }

  struct ExpandedRunpath: Hashable {
    let relativePath: String
    let isTrustedSystemPath: Bool
    let isExternalPath: Bool
  }

  struct ImageRecord {
    let sourceRelativePath: String
    let snapshotRelativePath: String
    let image: MCPMachOImage
    let sourceInheritedRunpaths: [ExpandedRunpath]
    let snapshotInheritedRunpaths: [ExpandedRunpath]
  }

  struct ResolvedDependency {
    let sourceRelativePath: String
    let snapshotRelativePath: String
    let descriptor: Int32
    let status: stat
  }

  struct FrameworkSymlinkBinding {
    let parentDescriptor: Int32
    let name: String
    let status: stat
    let target: String
  }

  struct SourceDirectoryFrame {
    let descriptor: Int32
    let sourceRelativePath: String
    let destinationRelativePath: String
    let initialStatus: stat
    let names: [String]
    var nextIndex: Int
    let ownsDescriptor: Bool
  }

  struct CopyState {
    let policy: MCPExecutableSnapshotPolicy
    let allowsTrustedHardLinks: Bool
    var createdEntries: [CreatedEntry] = []
    var createdDirectoryStatuses: [String: stat] = [:]
    var copiedFiles: Set<String> = []
    var copiedFileSources: [String: String] = [:]
    var copiedPackages: [String: String] = [:]
    var ownedRegularFiles: [MCPExecutableSnapshotOwnedFile] = []
    var copiedByteCount = off_t(0)
    var pathMetadataByteCount = Int64(0)
    var admittedEntryCount = 0
    var admittedRunpathCount = 0
    var admittedRunpathByteCount = Int64(0)

    init(
      policy: MCPExecutableSnapshotPolicy,
      allowsTrustedHardLinks: Bool = false
    ) {
      self.policy = policy
      self.allowsTrustedHardLinks = allowsTrustedHardLinks
    }

    mutating func admitEntry(
      relativePath: String,
      additionalPathMetadataBytes: Int64 = 0,
      copiedBytes: off_t
    ) throws {
      guard
        additionalPathMetadataBytes >= 0,
        copiedBytes >= 0,
        admittedEntryCount < policy.maximumEntriesPerSlot
      else {
        throw MCPClientSessionError.limitExceeded
      }
      let (pathBytes, entryPathOverflowed) = Int64(relativePath.utf8.count + 1)
        .addingReportingOverflow(additionalPathMetadataBytes)
      let (nextPathBytes, totalPathOverflowed) =
        pathMetadataByteCount.addingReportingOverflow(pathBytes)
      let (nextCopiedBytes, copiedOverflowed) =
        copiedByteCount.addingReportingOverflow(copiedBytes)
      guard
        !entryPathOverflowed,
        !totalPathOverflowed,
        !copiedOverflowed,
        nextPathBytes <= policy.maximumPathMetadataBytesPerSlot,
        nextCopiedBytes <= off_t(policy.maximumCopiedBytesPerSlot)
      else {
        throw MCPClientSessionError.limitExceeded
      }
      admittedEntryCount += 1
      pathMetadataByteCount = nextPathBytes
      copiedByteCount = nextCopiedBytes
    }

    mutating func admitRunpathBudget(
      source: [ExpandedRunpath],
      snapshot: [ExpandedRunpath]
    ) throws {
      guard
        source.count <= MCPExecutableSnapshot.maximumRunpathsPerImage,
        snapshot.count <= MCPExecutableSnapshot.maximumRunpathsPerImage
      else {
        throw MCPClientSessionError.limitExceeded
      }

      func byteCount(of runpaths: [ExpandedRunpath]) -> Int64? {
        var total = Int64(0)
        for runpath in runpaths {
          let (next, overflowed) = total.addingReportingOverflow(
            Int64(runpath.relativePath.utf8.count)
          )
          guard !overflowed else { return nil }
          total = next
        }
        return total
      }

      guard
        let sourceBytes = byteCount(of: source),
        let snapshotBytes = byteCount(of: snapshot),
        sourceBytes <= Int64(MCPExecutableSnapshot.maximumRunpathBytesPerImage),
        snapshotBytes <= Int64(MCPExecutableSnapshot.maximumRunpathBytesPerImage)
      else {
        throw MCPClientSessionError.limitExceeded
      }
      let imageCount = source.count + snapshot.count
      let (nextCount, countOverflowed) = admittedRunpathCount.addingReportingOverflow(imageCount)
      let imageBytes = sourceBytes + snapshotBytes
      let (nextBytes, bytesOverflowed) =
        admittedRunpathByteCount
        .addingReportingOverflow(imageBytes)
      guard
        !countOverflowed,
        !bytesOverflowed,
        nextCount <= MCPExecutableSnapshot.maximumClosureRunpaths,
        nextBytes <= Int64(MCPExecutableSnapshot.maximumClosureRunpathBytes)
      else {
        throw MCPClientSessionError.limitExceeded
      }
      admittedRunpathCount = nextCount
      admittedRunpathByteCount = nextBytes
    }
  }

  struct CreatedEntry: Sendable {
    enum Kind: Sendable {
      case directory
      case file
      case symbolicLink
    }

    let relativePath: String
    let kind: Kind
    let status: stat
  }

  struct SnapshotEntry: Sendable {
    let created: CreatedEntry
    let status: stat
  }

}
