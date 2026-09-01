import Darwin
import Foundation

extension MCPExecutableSnapshot {
  static func makePrivateDirectory(
    policy: MCPExecutableSnapshotPolicy,
    namespaceBasename: String = MCPExecutableSnapshotAdmission.productionNamespaceBasename,
    openClaimedSlot: @Sendable (Int32, String) -> Int32 = MCPExecutableSnapshotAdmission
      .openDirectoryForProduction
  ) throws -> PrivateDirectory {
    try MCPExecutableSnapshotAdmission.claimSlot(
      policy: policy,
      namespaceBasename: namespaceBasename,
      openClaimedSlot: openClaimedSlot
    )
  }

  static func ensureDestinationDirectory(
    _ relativePath: String,
    beneath rootDescriptor: Int32,
    copyState: inout CopyState
  ) throws -> Int32? {
    if relativePath.isEmpty {
      let duplicate = fcntl(rootDescriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
      guard duplicate >= 0 else {
        throw MCPClientSessionError.connectionClosed
      }
      return duplicate
    }
    guard
      let normalized = normalizeRelativePath(relativePath, relativeTo: ""),
      normalized == relativePath
    else {
      throw MCPClientSessionError.connectionClosed
    }
    var currentDescriptor = fcntl(rootDescriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
    guard currentDescriptor >= 0 else {
      throw MCPClientSessionError.connectionClosed
    }
    var accumulated: [String] = []
    for component in normalized.split(separator: "/").map(String.init) {
      accumulated.append(component)
      let currentPath = accumulated.joined(separator: "/")
      if copyState.createdDirectoryStatuses[currentPath] == nil {
        do {
          try copyState.admitEntry(relativePath: currentPath, copiedBytes: 0)
        } catch {
          Darwin.close(currentDescriptor)
          throw error
        }
        let result = component.withCString { name in
          mkdirat(currentDescriptor, name, 0o700)
        }
        guard result == 0 else {
          Darwin.close(currentDescriptor)
          throw MCPClientSessionError.connectionClosed
        }
        var createdStatus = stat()
        let createdStatusResult = component.withCString { name in
          fstatat(currentDescriptor, name, &createdStatus, AT_SYMLINK_NOFOLLOW)
        }
        guard
          createdStatusResult == 0,
          isAcceptableSnapshotDirectory(createdStatus)
        else {
          Darwin.close(currentDescriptor)
          throw MCPClientSessionError.connectionClosed
        }
        copyState.createdDirectoryStatuses[currentPath] = createdStatus
        copyState.createdEntries.append(
          CreatedEntry(relativePath: currentPath, kind: .directory, status: createdStatus)
        )
      }
      guard let expectedDirectoryStatus = copyState.createdDirectoryStatuses[currentPath] else {
        Darwin.close(currentDescriptor)
        throw MCPClientSessionError.connectionClosed
      }
      let nextDescriptor = component.withCString { name in
        openat(currentDescriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      }
      guard nextDescriptor >= 0 else {
        Darwin.close(currentDescriptor)
        throw MCPClientSessionError.connectionClosed
      }
      var status = stat()
      guard
        fstat(nextDescriptor, &status) == 0,
        isAcceptableSnapshotDirectory(status),
        sameDirectoryIdentity(expectedDirectoryStatus, status)
      else {
        Darwin.close(nextDescriptor)
        Darwin.close(currentDescriptor)
        throw MCPClientSessionError.connectionClosed
      }
      Darwin.close(currentDescriptor)
      currentDescriptor = nextDescriptor
    }
    return currentDescriptor
  }

  static func destinationParent(
    for relativePath: String,
    beneath rootDescriptor: Int32,
    copyState: inout CopyState
  ) throws -> (descriptor: Int32, basename: String) {
    guard let normalized = normalizeRelativePath(relativePath, relativeTo: ""),
      normalized == relativePath,
      let basename = normalized.split(separator: "/").last.map(String.init),
      !basename.isEmpty
    else {
      throw MCPClientSessionError.connectionClosed
    }
    let parentPath = directoryPath(of: normalized)
    guard
      let descriptor = try ensureDestinationDirectory(
        parentPath,
        beneath: rootDescriptor,
        copyState: &copyState
      )
    else {
      throw MCPClientSessionError.connectionClosed
    }
    return (descriptor, basename)
  }

  static func openSourceDirectory(
    _ relativePath: String,
    beneath rootDescriptor: Int32,
    missingIsAllowed: Bool,
    requiresRootOwnership: Bool = false
  ) throws -> Int32? {
    guard let normalized = normalizeRelativePath(relativePath, relativeTo: ""),
      normalized == relativePath
    else {
      throw MCPClientSessionError.connectionClosed
    }
    var currentDescriptor = fcntl(rootDescriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
    guard currentDescriptor >= 0 else {
      throw MCPClientSessionError.connectionClosed
    }
    for component in normalized.split(separator: "/").map(String.init) {
      let nextDescriptor = component.withCString { name in
        openat(currentDescriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      }
      if nextDescriptor < 0 {
        let openError = errno
        Darwin.close(currentDescriptor)
        if missingIsAllowed && (openError == ENOENT || openError == ENOTDIR) {
          return nil
        }
        throw MCPClientSessionError.connectionClosed
      }
      var status = stat()
      guard
        fstat(nextDescriptor, &status) == 0,
        isAcceptableSourceDirectory(
          status,
          requiresRootOwnership: requiresRootOwnership
        )
      else {
        Darwin.close(nextDescriptor)
        Darwin.close(currentDescriptor)
        throw MCPClientSessionError.connectionClosed
      }
      Darwin.close(currentDescriptor)
      currentDescriptor = nextDescriptor
    }
    return currentDescriptor
  }

  static func openSourceRegularFile(
    _ relativePath: String,
    beneath rootDescriptor: Int32,
    requireExecutable: Bool,
    missingIsAllowed: Bool,
    allowsTrustedHardLinks: Bool = false
  ) throws -> (descriptor: Int32, status: stat)? {
    guard let normalized = normalizeRelativePath(relativePath, relativeTo: ""),
      normalized == relativePath,
      let basename = normalized.split(separator: "/").last.map(String.init)
    else {
      throw MCPClientSessionError.connectionClosed
    }
    let parentPath = directoryPath(of: normalized)
    guard
      let parentDescriptor = try openSourceDirectory(
        parentPath,
        beneath: rootDescriptor,
        missingIsAllowed: missingIsAllowed,
        requiresRootOwnership: allowsTrustedHardLinks
      )
    else {
      return nil
    }
    defer { Darwin.close(parentDescriptor) }
    let descriptor = basename.withCString { name in
      openat(
        parentDescriptor,
        name,
        O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
      )
    }
    if descriptor < 0 {
      let openError = errno
      if missingIsAllowed && (openError == ENOENT || openError == ENOTDIR) {
        return nil
      }
    }
    guard descriptor >= 0 else {
      throw MCPClientSessionError.connectionClosed
    }
    var status = stat()
    guard
      fstat(descriptor, &status) == 0,
      isAcceptableRuntimeSource(
        status,
        requireExecutable: requireExecutable,
        allowsTrustedHardLinks: allowsTrustedHardLinks
      )
    else {
      Darwin.close(descriptor)
      throw MCPClientSessionError.connectionClosed
    }
    return (descriptor, status)
  }

  static func readDestinationImage(
    _ relativePath: String,
    beneath rootDescriptor: Int32
  ) throws -> MCPMachOImage? {
    guard let source = try openSnapshotRegularFile(relativePath, beneath: rootDescriptor) else {
      throw MCPClientSessionError.connectionClosed
    }
    defer { Darwin.close(source.descriptor) }
    return try MCPMachOImage.read(from: source.descriptor, fileSize: source.status.st_size)
  }

  private static func openSnapshotRegularFile(
    _ relativePath: String,
    beneath rootDescriptor: Int32
  ) throws -> (descriptor: Int32, status: stat)? {
    guard let normalized = normalizeRelativePath(relativePath, relativeTo: ""),
      normalized == relativePath,
      let basename = normalized.split(separator: "/").last.map(String.init),
      let parent = openSnapshotDirectory(
        directoryPath(of: normalized),
        beneath: rootDescriptor
      )
    else {
      return nil
    }
    defer { Darwin.close(parent) }
    let descriptor = basename.withCString { name in
      openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    }
    guard descriptor >= 0 else { return nil }
    var status = stat()
    guard
      fstat(descriptor, &status) == 0,
      status.st_mode & S_IFMT == S_IFREG,
      status.st_uid == geteuid(),
      status.st_nlink == 1,
      status.st_size >= 0,
      status.st_size <= maximumExecutableBytes,
      status.st_mode & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID) == 0
    else {
      Darwin.close(descriptor)
      return nil
    }
    return (descriptor, status)
  }

  static func openSnapshotDirectory(
    _ relativePath: String,
    beneath rootDescriptor: Int32
  ) -> Int32? {
    guard let normalized = normalizeRelativePath(relativePath, relativeTo: ""),
      normalized == relativePath
    else {
      return nil
    }
    var descriptor = fcntl(rootDescriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
    guard descriptor >= 0 else { return nil }
    for component in normalized.split(separator: "/").map(String.init) {
      let next = component.withCString { name in
        openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      }
      guard next >= 0 else {
        Darwin.close(descriptor)
        return nil
      }
      var status = stat()
      guard
        fstat(next, &status) == 0,
        isAcceptableSnapshotDirectory(status)
      else {
        Darwin.close(next)
        Darwin.close(descriptor)
        return nil
      }
      Darwin.close(descriptor)
      descriptor = next
    }
    return descriptor
  }

  static func directoryEntryNames(_ descriptor: Int32) throws -> [String] {
    let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
    guard duplicate >= 0, let directory = fdopendir(duplicate) else {
      if duplicate >= 0 { Darwin.close(duplicate) }
      throw MCPClientSessionError.connectionClosed
    }
    defer { closedir(directory) }
    var names: [String] = []
    errno = 0
    while let entry = readdir(directory) {
      let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
          String(cString: $0)
        }
      }
      guard name != ".", name != ".." else { continue }
      guard !name.isEmpty, !name.contains("/"), !name.contains("\0"), name.utf8.count <= 255,
        canCreateBundleEntry(currentCount: names.count)
      else {
        throw MCPClientSessionError.connectionClosed
      }
      names.append(name)
      errno = 0
    }
    guard errno == 0 else {
      throw MCPClientSessionError.connectionClosed
    }
    return names.sorted()
  }

}
