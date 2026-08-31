import Darwin

final class MCPExecutableSnapshot: Sendable {
  static let maximumExecutableBytes: off_t = 256 * 1_024 * 1_024
  static let maximumBundleBytes: off_t = 768 * 1_024 * 1_024
  static let maximumBundleEntries = 32_768
  static let maximumBundleImages = 512
  static let maximumSnapshotPathBytes = 4_096
  static let maximumSnapshotPathDepth = 64
  static let maximumSymbolicLinkBytes = 4_096

  let executablePath: String
  let status: stat

  private let parentDescriptor: Int32
  private let directoryBasename: String
  private let directoryDescriptor: Int32
  private let directoryStatus: stat
  private let executableDescriptor: Int32
  private let entries: [SnapshotEntry]
  private let cleanupAuditHooks: CleanupAuditHooks?

  private init(
    executablePath: String,
    status: stat,
    parentDescriptor: Int32,
    directoryBasename: String,
    directoryDescriptor: Int32,
    directoryStatus: stat,
    executableDescriptor: Int32,
    entries: [SnapshotEntry],
    cleanupAuditHooks: CleanupAuditHooks?
  ) {
    self.executablePath = executablePath
    self.status = status
    self.parentDescriptor = parentDescriptor
    self.directoryBasename = directoryBasename
    self.directoryDescriptor = directoryDescriptor
    self.directoryStatus = directoryStatus
    self.executableDescriptor = executableDescriptor
    self.entries = entries
    self.cleanupAuditHooks = cleanupAuditHooks
  }

  deinit {
    Darwin.close(executableDescriptor)
    Self.removeCreatedEntries(
      entries.map(\.created),
      from: directoryDescriptor,
      auditHooks: cleanupAuditHooks
    )
    Self.removePrivateDirectory(
      parentDescriptor: parentDescriptor,
      basename: directoryBasename,
      directoryStatus: directoryStatus,
      auditHooks: cleanupAuditHooks
    )
    Darwin.close(directoryDescriptor)
    Darwin.close(parentDescriptor)
  }

  static func create(
    from sourceDescriptor: Int32,
    initialStatus: stat,
    sourcePath: String? = nil,
    afterSourceValidation: (@Sendable (_ snapshotPath: String) -> Void)?,
    cleanupAuditHooks: CleanupAuditHooks? = nil
  ) throws -> MCPExecutableSnapshot {
    guard isAcceptableSource(initialStatus) else {
      throw MCPClientSessionError.connectionClosed
    }

    let privateDirectory = try makePrivateDirectory()
    var copyState = CopyState()
    var executableDescriptor = Int32(-1)
    var completed = false
    defer {
      if !completed {
        if executableDescriptor >= 0 { Darwin.close(executableDescriptor) }
        removeCreatedEntries(
          copyState.createdEntries,
          from: privateDirectory.descriptor,
          auditHooks: cleanupAuditHooks
        )
        removePrivateDirectory(
          parentDescriptor: privateDirectory.parentDescriptor,
          basename: privateDirectory.basename,
          directoryStatus: privateDirectory.initialStatus,
          auditHooks: cleanupAuditHooks
        )
        Darwin.close(privateDirectory.descriptor)
        Darwin.close(privateDirectory.parentDescriptor)
      }
    }

    let executableRelativePath: String
    let executableStatus: stat
    if let sourcePath, let layout = bundleLayout(for: sourcePath) {
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
      parentDescriptor: privateDirectory.parentDescriptor,
      directoryBasename: privateDirectory.basename,
      directoryDescriptor: privateDirectory.descriptor,
      directoryStatus: finalDirectoryStatus,
      executableDescriptor: executableDescriptor,
      entries: snapshotEntries,
      cleanupAuditHooks: cleanupAuditHooks
    )
  }

  func isIntact() -> Bool {
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

  struct ExpandedRunpath: Equatable {
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
    var createdEntries: [CreatedEntry] = []
    var createdDirectories: Set<String> = []
    var copiedFiles: Set<String> = []
    var copiedFileSources: [String: String] = [:]
    var copiedPackages: [String: String] = [:]
    var totalByteCount = off_t(0)
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

  struct CleanupAuditHooks: Sendable {
    let afterEntryIdentityValidation:
      (@Sendable (_ parentDescriptor: Int32, _ basename: String) -> Void)?
    let afterRootIdentityValidation:
      (@Sendable (_ parentDescriptor: Int32, _ basename: String) -> Void)?
    let afterQuarantinedEntryIdentityValidation:
      (@Sendable (_ parentDescriptor: Int32, _ basename: String) -> Void)?
    let afterQuarantinedRootIdentityValidation:
      (@Sendable (_ parentDescriptor: Int32, _ basename: String) -> Void)?

    init(
      afterEntryIdentityValidation:
        (@Sendable (_ parentDescriptor: Int32, _ basename: String) -> Void)? = nil,
      afterRootIdentityValidation:
        (@Sendable (_ parentDescriptor: Int32, _ basename: String) -> Void)? = nil,
      afterQuarantinedEntryIdentityValidation:
        (@Sendable (_ parentDescriptor: Int32, _ basename: String) -> Void)? = nil,
      afterQuarantinedRootIdentityValidation:
        (@Sendable (_ parentDescriptor: Int32, _ basename: String) -> Void)? = nil
    ) {
      self.afterEntryIdentityValidation = afterEntryIdentityValidation
      self.afterRootIdentityValidation = afterRootIdentityValidation
      self.afterQuarantinedEntryIdentityValidation =
        afterQuarantinedEntryIdentityValidation
      self.afterQuarantinedRootIdentityValidation =
        afterQuarantinedRootIdentityValidation
    }
  }
}
