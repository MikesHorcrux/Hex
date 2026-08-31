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
      && (status.st_uid == 0 || status.st_uid == effectiveUserID)
      && (status.st_nlink == 1
        || (allowsTrustedHardLinks && status.st_uid == 0 && status.st_nlink > 1))
      && status.st_size >= 0
      && status.st_size <= maximumExecutableBytes
      && (!requireExecutable
        || hasExecutionPermission(status, effectiveUserID: effectiveUserID))
      && status.st_mode & (S_ISUID | S_ISGID) == 0
      && status.st_mode & (S_IWGRP | S_IWOTH) == 0
  }

  /// Xcode's signed app bundles may contain root-owned hard-linked resources. Permit
  /// those aliases only after anchoring the complete bundle path and nested signature to
  /// Apple's Xcode requirement; all other snapshot sources retain the nlink == 1 rule.
  static func isTrustedSignedXcodeBundle(rootPath: String) -> Bool {
    guard
      rootPath.hasSuffix(".app"),
      rootPath.hasPrefix("/"),
      !rootPath.contains("\0"),
      (rootPath as NSString).standardizingPath == rootPath,
      isRootOwnedUnwritableDirectory(rootPath)
    else {
      return false
    }

    var staticCode: SecStaticCode?
    guard
      SecStaticCodeCreateWithPath(
        URL(fileURLWithPath: rootPath, isDirectory: true) as CFURL,
        SecCSFlags(rawValue: kSecCSDefaultFlags),
        &staticCode
      ) == errSecSuccess,
      let staticCode
    else {
      return false
    }

    var requirement: SecRequirement?
    guard
      SecRequirementCreateWithString(
        "anchor apple generic and identifier \"com.apple.dt.Xcode\"" as CFString,
        SecCSFlags(rawValue: kSecCSDefaultFlags),
        &requirement
      ) == errSecSuccess,
      let requirement
    else {
      return false
    }

    let flags = SecCSFlags(
      rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate
    )
    return SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess
  }

  static func isAcceptableSourceDirectory(_ status: stat) -> Bool {
    status.st_mode & S_IFMT == S_IFDIR
      && (status.st_uid == 0 || status.st_uid == geteuid())
      && status.st_mode & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID) == 0
  }

  static func isAcceptableSnapshotDirectory(_ status: stat) -> Bool {
    status.st_mode & S_IFMT == S_IFDIR
      && status.st_uid == geteuid()
      && status.st_mode & 0o077 == 0
  }

  private static func isRootOwnedUnwritableDirectory(_ path: String) -> Bool {
    let components = path.split(separator: "/").map(String.init)
    guard !components.isEmpty else { return false }
    var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { return false }
    defer { Darwin.close(descriptor) }

    for component in components {
      let nextDescriptor = component.withCString { name in
        openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      }
      guard nextDescriptor >= 0 else { return false }
      var status = stat()
      let valid =
        fstat(nextDescriptor, &status) == 0
        && status.st_mode & S_IFMT == S_IFDIR
        && status.st_uid == 0
        && status.st_mode & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID) == 0
      guard valid else {
        Darwin.close(nextDescriptor)
        return false
      }
      Darwin.close(descriptor)
      descriptor = nextDescriptor
    }
    return true
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
