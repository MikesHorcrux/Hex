import Darwin
import Foundation
import Security

extension MCPExecutableSnapshot {
  static func nextBundleByteCount(current: off_t, adding: off_t) -> off_t? {
    guard current >= 0, adding >= 0 else { return nil }
    let (total, overflowed) = current.addingReportingOverflow(adding)
    guard !overflowed, total <= maximumBundleBytes else { return nil }
    return total
  }

  static func canCreateBundleEntry(currentCount: Int) -> Bool {
    currentCount >= 0 && currentCount < maximumBundleEntries
  }

  static func isAcceptableBundleImageCount(_ count: Int) -> Bool {
    count > 0 && count <= maximumBundleImages
  }

  static func normalizeRelativePath(
    _ path: String,
    relativeTo basePath: String
  ) -> String? {
    guard !path.hasPrefix("/"), !path.contains("\0"),
      path.utf8.count <= maximumSnapshotPathBytes
    else {
      return nil
    }
    var components = basePath.split(separator: "/").map(String.init)
    guard components.count <= maximumSnapshotPathDepth else { return nil }
    for component in path.split(separator: "/", omittingEmptySubsequences: false) {
      switch component {
      case "", ".":
        continue
      case "..":
        guard !components.isEmpty else { return nil }
        components.removeLast()
      default:
        guard component.utf8.count <= 255,
          components.count < maximumSnapshotPathDepth
        else {
          return nil
        }
        components.append(String(component))
      }
    }
    let normalized = components.joined(separator: "/")
    guard normalized.utf8.count <= maximumSnapshotPathBytes else { return nil }
    return normalized
  }

  static func directoryPath(of relativePath: String) -> String {
    relativePath.split(separator: "/").dropLast().joined(separator: "/")
  }

  static func isTrustedSystemPath(_ path: String) -> Bool {
    guard path.hasPrefix("/"), !path.contains("\0") else { return false }
    let standardizedPath = (path as NSString).standardizingPath
    guard standardizedPath == path else { return false }
    return standardizedPath == "/System"
      || standardizedPath.hasPrefix("/System/")
      || standardizedPath == "/usr/lib"
      || standardizedPath.hasPrefix("/usr/lib/")
      || standardizedPath == "/Library/Apple/System"
      || standardizedPath.hasPrefix("/Library/Apple/System/")
  }

  static func isAcceptableRuntimeSource(
    _ status: stat,
    requireExecutable: Bool,
    allowsTrustedHardLinks: Bool = false
  ) -> Bool {
    let effectiveUserID = geteuid()
    return status.st_mode & S_IFMT == S_IFREG
      && (status.st_uid == 0
        || (!allowsTrustedHardLinks && status.st_uid == effectiveUserID))
      && (status.st_nlink == 1
        || (allowsTrustedHardLinks && status.st_uid == 0 && status.st_nlink > 1))
      && status.st_size >= 0
      && status.st_size <= maximumExecutableBytes
      && (!requireExecutable
        || hasExecutionPermission(status, effectiveUserID: effectiveUserID))
      && status.st_mode & (S_ISUID | S_ISGID) == 0
      && status.st_mode & (S_IWGRP | S_IWOTH) == 0
  }

  static let xcodeCodeSigningRequirement =
    #"(anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] /* exists */ or anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = "59GAB85EFG") and identifier "com.apple.dt.Xcode""#

  static let standardApplicationsPath = "/Applications"
  static let standardXcodeBundlePath = "/Applications/Xcode.app"
  static let standardApplicationsComponent = "Applications"
  static let standardXcodeBundleComponent = "Xcode.app"
  static let standardApplicationsGroupID = gid_t(80)

  /// Xcode's signed app bundles may contain root-owned hard-linked resources. Permit
  /// those aliases only after anchoring the exact standard bundle path and nested signature
  /// to Apple's Xcode requirement; all other snapshot sources retain the nlink == 1 rule.
  static func isTrustedSignedXcodeBundle(rootPath: String) -> Bool {
    trustedSignedXcodeBundle(rootPath: rootPath) != nil
  }

  static func trustedSignedXcodeBundle(rootPath: String) -> TrustedXcodeBundle? {
    guard let bundle = openTrustedXcodeBundle(rootPath: rootPath) else { return nil }
    guard bundle.isIntact() else { return nil }

    var staticCode: SecStaticCode?
    guard
      SecStaticCodeCreateWithPath(
        URL(fileURLWithPath: rootPath, isDirectory: true) as CFURL,
        SecCSFlags(rawValue: 0),
        &staticCode
      ) == errSecSuccess,
      let staticCode
    else {
      return nil
    }

    var requirement: SecRequirement?
    guard
      SecRequirementCreateWithString(
        xcodeCodeSigningRequirement as CFString,
        SecCSFlags(rawValue: 0),
        &requirement
      ) == errSecSuccess,
      let requirement
    else {
      return nil
    }

    let flags = SecCSFlags(
      rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate
    )
    guard SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess else {
      return nil
    }
    guard bundle.isIntact() else { return nil }
    return bundle
  }

  static func isAcceptableSourceDirectory(
    _ status: stat,
    requiresRootOwnership: Bool = false
  ) -> Bool {
    status.st_mode & S_IFMT == S_IFDIR
      && (status.st_uid == 0
        || (!requiresRootOwnership && status.st_uid == geteuid()))
      && status.st_mode & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID) == 0
  }

  static func isAcceptableSnapshotDirectory(_ status: stat) -> Bool {
    status.st_mode & S_IFMT == S_IFDIR
      && status.st_uid == geteuid()
      && status.st_mode & 0o077 == 0
  }

  static func isExactTrustedXcodeBundlePath(_ path: String) -> Bool {
    path == standardXcodeBundlePath
      && path.hasPrefix("/")
      && !path.contains("\0")
      && (path as NSString).standardizingPath == path
  }

  static func isAcceptableStandardApplicationsDirectory(_ status: stat) -> Bool {
    status.st_mode & S_IFMT == S_IFDIR
      && status.st_uid == 0
      && status.st_gid == standardApplicationsGroupID
      && status.st_mode & 0o7777 == 0o775
  }

  static func isAcceptableTrustedBundleComponent(_ status: stat) -> Bool {
    let fileType = status.st_mode & S_IFMT
    guard fileType == S_IFDIR || fileType == S_IFREG || fileType == S_IFLNK else {
      return false
    }
    let writableBits = fileType == S_IFLNK ? mode_t(0) : S_IWGRP | S_IWOTH
    return status.st_uid == 0
      && status.st_mode & (writableBits | S_ISUID | S_ISGID) == 0
  }

  static func hasStableTrustedXcodePathIdentities(
    ancestorInitialStatus: stat,
    ancestorDescriptorStatus: stat,
    ancestorPathStatus: stat,
    bundleInitialStatus: stat,
    bundleDescriptorStatus: stat,
    bundlePathStatus: stat
  ) -> Bool {
    isAcceptableStandardApplicationsDirectory(ancestorInitialStatus)
      && isAcceptableStandardApplicationsDirectory(ancestorDescriptorStatus)
      && isAcceptableStandardApplicationsDirectory(ancestorPathStatus)
      && bundleInitialStatus.st_mode & S_IFMT == S_IFDIR
      && bundleDescriptorStatus.st_mode & S_IFMT == S_IFDIR
      && bundlePathStatus.st_mode & S_IFMT == S_IFDIR
      && isAcceptableTrustedBundleComponent(bundleInitialStatus)
      && isAcceptableTrustedBundleComponent(bundleDescriptorStatus)
      && isAcceptableTrustedBundleComponent(bundlePathStatus)
      && sameSourceIdentityAndMetadata(ancestorInitialStatus, ancestorDescriptorStatus)
      && sameSourceIdentityAndMetadata(ancestorInitialStatus, ancestorPathStatus)
      && sameSourceIdentityAndMetadata(bundleInitialStatus, bundleDescriptorStatus)
      && sameSourceIdentityAndMetadata(bundleInitialStatus, bundlePathStatus)
  }

  final class TrustedXcodeBundle: Sendable {
    let rootPath: String
    let rootDescriptor: Int32
    let applicationsDescriptor: Int32
    let applicationsStatus: stat
    let bundleDescriptor: Int32
    let bundleStatus: stat

    init(
      rootPath: String,
      rootDescriptor: Int32,
      applicationsDescriptor: Int32,
      applicationsStatus: stat,
      bundleDescriptor: Int32,
      bundleStatus: stat
    ) {
      self.rootPath = rootPath
      self.rootDescriptor = rootDescriptor
      self.applicationsDescriptor = applicationsDescriptor
      self.applicationsStatus = applicationsStatus
      self.bundleDescriptor = bundleDescriptor
      self.bundleStatus = bundleStatus
    }

    deinit {
      Darwin.close(bundleDescriptor)
      Darwin.close(applicationsDescriptor)
      Darwin.close(rootDescriptor)
    }

    func isIntact() -> Bool {
      guard MCPExecutableSnapshot.isExactTrustedXcodeBundlePath(rootPath) else {
        return false
      }
      var ancestorDescriptorStatus = stat()
      var ancestorPathStatus = stat()
      var bundleDescriptorStatus = stat()
      var bundlePathStatus = stat()
      guard
        fstat(applicationsDescriptor, &ancestorDescriptorStatus) == 0,
        MCPExecutableSnapshot.standardApplicationsComponent.withCString({ name in
          fstatat(rootDescriptor, name, &ancestorPathStatus, AT_SYMLINK_NOFOLLOW)
        }) == 0,
        fstat(bundleDescriptor, &bundleDescriptorStatus) == 0,
        MCPExecutableSnapshot.standardXcodeBundleComponent.withCString({ name in
          fstatat(
            applicationsDescriptor,
            name,
            &bundlePathStatus,
            AT_SYMLINK_NOFOLLOW
          )
        }) == 0
      else {
        return false
      }
      return MCPExecutableSnapshot.hasStableTrustedXcodePathIdentities(
        ancestorInitialStatus: applicationsStatus,
        ancestorDescriptorStatus: ancestorDescriptorStatus,
        ancestorPathStatus: ancestorPathStatus,
        bundleInitialStatus: bundleStatus,
        bundleDescriptorStatus: bundleDescriptorStatus,
        bundlePathStatus: bundlePathStatus
      )
    }
  }

  private static func openTrustedXcodeBundle(rootPath: String) -> TrustedXcodeBundle? {
    guard isExactTrustedXcodeBundlePath(rootPath) else { return nil }

    let rootDescriptor = Darwin.open(
      "/",
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard rootDescriptor >= 0 else { return nil }
    var ownsRootDescriptor = true
    defer {
      if ownsRootDescriptor { Darwin.close(rootDescriptor) }
    }

    let applicationsDescriptor = standardApplicationsComponent.withCString { name in
      openat(rootDescriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard applicationsDescriptor >= 0 else { return nil }
    var ownsApplicationsDescriptor = true
    defer {
      if ownsApplicationsDescriptor { Darwin.close(applicationsDescriptor) }
    }

    var ancestorStatus = stat()
    guard
      fstat(applicationsDescriptor, &ancestorStatus) == 0,
      isAcceptableStandardApplicationsDirectory(ancestorStatus)
    else {
      return nil
    }

    let bundleDescriptor = standardXcodeBundleComponent.withCString { name in
      openat(
        applicationsDescriptor,
        name,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
      )
    }
    guard bundleDescriptor >= 0 else { return nil }
    var ownsBundleDescriptor = true
    defer {
      if ownsBundleDescriptor { Darwin.close(bundleDescriptor) }
    }

    var bundleStatus = stat()
    guard
      fstat(bundleDescriptor, &bundleStatus) == 0,
      bundleStatus.st_mode & S_IFMT == S_IFDIR,
      isAcceptableTrustedBundleComponent(bundleStatus)
    else {
      return nil
    }

    let bundle = TrustedXcodeBundle(
      rootPath: rootPath,
      rootDescriptor: rootDescriptor,
      applicationsDescriptor: applicationsDescriptor,
      applicationsStatus: ancestorStatus,
      bundleDescriptor: bundleDescriptor,
      bundleStatus: bundleStatus
    )
    ownsRootDescriptor = false
    ownsApplicationsDescriptor = false
    ownsBundleDescriptor = false
    return bundle
  }

  static func hasExecutionPermission(
    _ status: stat,
    effectiveUserID: uid_t
  ) -> Bool {
    if status.st_uid == effectiveUserID {
      return status.st_mode & S_IXUSR != 0
    }
    if effectiveUserID == 0 {
      return status.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0
    }
    return status.st_mode & S_IXOTH != 0
  }

  static func sameSourceIdentityAndMetadata(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev
      && lhs.st_ino == rhs.st_ino
      && lhs.st_mode == rhs.st_mode
      && lhs.st_nlink == rhs.st_nlink
      && lhs.st_uid == rhs.st_uid
      && lhs.st_gid == rhs.st_gid
      && lhs.st_size == rhs.st_size
      && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
      && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
      && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
      && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
  }

  static func sameDirectoryIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev
      && lhs.st_ino == rhs.st_ino
      && lhs.st_mode & S_IFMT == S_IFDIR
      && rhs.st_mode & S_IFMT == S_IFDIR
  }

  static func sameSnapshotDirectoryIdentityAndPermissions(
    _ lhs: stat,
    _ rhs: stat
  ) -> Bool {
    lhs.st_dev == rhs.st_dev
      && lhs.st_ino == rhs.st_ino
      && lhs.st_mode == rhs.st_mode
      && lhs.st_mode & S_IFMT == S_IFDIR
      && rhs.st_mode & S_IFMT == S_IFDIR
      && lhs.st_uid == geteuid()
      && rhs.st_uid == geteuid()
  }

  static func sameCreatedEntryIdentity(
    _ lhs: stat,
    _ rhs: stat,
    kind: CreatedEntry.Kind
  ) -> Bool {
    let expectedType: mode_t
    switch kind {
    case .directory: expectedType = S_IFDIR
    case .file: expectedType = S_IFREG
    case .symbolicLink: expectedType = S_IFLNK
    }
    return lhs.st_dev == rhs.st_dev
      && lhs.st_ino == rhs.st_ino
      && lhs.st_mode & S_IFMT == expectedType
      && rhs.st_mode & S_IFMT == expectedType
      && lhs.st_uid == geteuid()
      && rhs.st_uid == geteuid()
  }

  static func sameSnapshotIdentityAndMetadata(_ lhs: stat, _ rhs: stat) -> Bool {
    sameSourceIdentityAndMetadata(lhs, rhs)
  }
}
