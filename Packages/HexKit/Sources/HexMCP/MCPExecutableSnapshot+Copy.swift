import Darwin

extension MCPExecutableSnapshot {
  static func copySourceDirectoryTree(
    sourceRelativePath: String,
    destinationRelativePath: String,
    boundDependency: ResolvedDependency,
    sourceRootDescriptor: Int32,
    destinationRootDescriptor: Int32,
    copyState: inout CopyState
  ) throws {
    guard
      let sourceDescriptor = try openSourceDirectory(
        sourceRelativePath,
        beneath: sourceRootDescriptor,
        missingIsAllowed: false
      )
    else {
      throw MCPClientSessionError.connectionClosed
    }
    defer { Darwin.close(sourceDescriptor) }
    if let destinationDescriptor = try ensureDestinationDirectory(
      destinationRelativePath,
      beneath: destinationRootDescriptor,
      copyState: &copyState
    ) {
      Darwin.close(destinationDescriptor)
    }
    try copySourceDirectoryContents(
      sourceDescriptor: sourceDescriptor,
      sourceRelativePath: sourceRelativePath,
      destinationRelativePath: destinationRelativePath,
      sourcePackageRoot: sourceRelativePath,
      destinationPackageRoot: destinationRelativePath,
      boundDependency: boundDependency,
      destinationRootDescriptor: destinationRootDescriptor,
      copyState: &copyState
    )
    guard
      copyState.copiedFileSources[boundDependency.snapshotRelativePath]
        == boundDependency.sourceRelativePath
    else {
      throw MCPClientSessionError.connectionClosed
    }
  }

  private static func copySourceDirectoryContents(
    sourceDescriptor: Int32,
    sourceRelativePath: String,
    destinationRelativePath: String,
    sourcePackageRoot: String,
    destinationPackageRoot: String,
    boundDependency: ResolvedDependency,
    destinationRootDescriptor: Int32,
    copyState: inout CopyState
  ) throws {
    var rootStatus = stat()
    guard
      fstat(sourceDescriptor, &rootStatus) == 0,
      isAcceptableSourceDirectory(rootStatus)
    else {
      throw MCPClientSessionError.connectionClosed
    }
    var stack = [
      SourceDirectoryFrame(
        descriptor: sourceDescriptor,
        sourceRelativePath: sourceRelativePath,
        destinationRelativePath: destinationRelativePath,
        initialStatus: rootStatus,
        names: try directoryEntryNames(sourceDescriptor),
        nextIndex: 0,
        ownsDescriptor: false
      )
    ]
    defer {
      for frame in stack where frame.ownsDescriptor {
        Darwin.close(frame.descriptor)
      }
    }

    while let frameIndex = stack.indices.last {
      if stack[frameIndex].nextIndex == stack[frameIndex].names.count {
        let completedFrame = stack.removeLast()
        var finalStatus = stat()
        let isStable =
          fstat(completedFrame.descriptor, &finalStatus) == 0
          && sameSourceIdentityAndMetadata(completedFrame.initialStatus, finalStatus)
        if completedFrame.ownsDescriptor { Darwin.close(completedFrame.descriptor) }
        guard isStable else {
          throw MCPClientSessionError.connectionClosed
        }
        continue
      }

      let name = stack[frameIndex].names[stack[frameIndex].nextIndex]
      stack[frameIndex].nextIndex += 1
      let parentDescriptor = stack[frameIndex].descriptor
      let sourceChildPath = stack[frameIndex].sourceRelativePath + "/" + name
      let destinationChildPath = stack[frameIndex].destinationRelativePath + "/" + name
      var childStatus = stat()
      let statusResult = name.withCString { childName in
        fstatat(parentDescriptor, childName, &childStatus, AT_SYMLINK_NOFOLLOW)
      }
      guard statusResult == 0 else {
        throw MCPClientSessionError.connectionClosed
      }
      switch childStatus.st_mode & S_IFMT {
      case S_IFDIR:
        guard isAcceptableSourceDirectory(childStatus) else {
          throw MCPClientSessionError.connectionClosed
        }
        let childDescriptor = name.withCString { childName in
          openat(
            parentDescriptor,
            childName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
          )
        }
        guard childDescriptor >= 0 else {
          throw MCPClientSessionError.connectionClosed
        }
        var openedStatus = stat()
        guard
          fstat(childDescriptor, &openedStatus) == 0,
          sameSourceIdentityAndMetadata(childStatus, openedStatus)
        else {
          Darwin.close(childDescriptor)
          throw MCPClientSessionError.connectionClosed
        }
        do {
          if let destinationDescriptor = try ensureDestinationDirectory(
            destinationChildPath,
            beneath: destinationRootDescriptor,
            copyState: &copyState
          ) {
            Darwin.close(destinationDescriptor)
          }
          stack.append(
            SourceDirectoryFrame(
              descriptor: childDescriptor,
              sourceRelativePath: sourceChildPath,
              destinationRelativePath: destinationChildPath,
              initialStatus: openedStatus,
              names: try directoryEntryNames(childDescriptor),
              nextIndex: 0,
              ownsDescriptor: true
            )
          )
        } catch {
          Darwin.close(childDescriptor)
          throw error
        }
      case S_IFREG:
        let childDescriptor: Int32
        let openedStatus: stat
        let ownsChildDescriptor: Bool
        if sourceChildPath == boundDependency.sourceRelativePath {
          childDescriptor = boundDependency.descriptor
          var boundStatus = stat()
          guard
            fstat(childDescriptor, &boundStatus) == 0,
            sameSourceIdentityAndMetadata(boundDependency.status, boundStatus),
            sameSourceIdentityAndMetadata(childStatus, boundStatus)
          else {
            throw MCPClientSessionError.connectionClosed
          }
          openedStatus = boundStatus
          ownsChildDescriptor = false
        } else {
          childDescriptor = name.withCString { childName in
            openat(
              parentDescriptor,
              childName,
              O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
          }
          guard childDescriptor >= 0 else {
            throw MCPClientSessionError.connectionClosed
          }
          var newlyOpenedStatus = stat()
          guard
            fstat(childDescriptor, &newlyOpenedStatus) == 0,
            sameSourceIdentityAndMetadata(childStatus, newlyOpenedStatus)
          else {
            Darwin.close(childDescriptor)
            throw MCPClientSessionError.connectionClosed
          }
          openedStatus = newlyOpenedStatus
          ownsChildDescriptor = true
        }
        do {
          let copied = try copyRegularFile(
            sourceDescriptor: childDescriptor,
            initialStatus: openedStatus,
            sourceRelativePath: sourceChildPath,
            destinationRelativePath: destinationChildPath,
            destinationRootDescriptor: destinationRootDescriptor,
            requireExecutable: false,
            copyState: &copyState,
            beforeCopy: nil
          )
          Darwin.close(copied.descriptor)
          if ownsChildDescriptor { Darwin.close(childDescriptor) }
        } catch {
          if ownsChildDescriptor { Darwin.close(childDescriptor) }
          throw error
        }
      case S_IFLNK:
        try copySymbolicLink(
          name: name,
          initialStatus: childStatus,
          sourceParentDescriptor: parentDescriptor,
          sourceRelativePath: sourceChildPath,
          destinationRelativePath: destinationChildPath,
          sourcePackageRoot: sourcePackageRoot,
          destinationPackageRoot: destinationPackageRoot,
          destinationRootDescriptor: destinationRootDescriptor,
          copyState: &copyState
        )
      default:
        throw MCPClientSessionError.connectionClosed
      }
    }
  }

  static func copyRegularFile(
    sourceDescriptor: Int32,
    initialStatus: stat,
    sourceRelativePath: String,
    destinationRelativePath: String,
    destinationRootDescriptor: Int32,
    requireExecutable: Bool,
    copyState: inout CopyState,
    beforeCopy: (() -> Void)?
  ) throws -> (descriptor: Int32, status: stat) {
    guard
      isAcceptableRuntimeSource(initialStatus, requireExecutable: requireExecutable),
      canCreateBundleEntry(currentCount: copyState.createdEntries.count)
    else {
      throw MCPClientSessionError.connectionClosed
    }
    guard
      let nextTotal = nextBundleByteCount(
        current: copyState.totalByteCount,
        adding: initialStatus.st_size
      )
    else {
      throw MCPClientSessionError.connectionClosed
    }
    let parent = try destinationParent(
      for: destinationRelativePath,
      beneath: destinationRootDescriptor,
      copyState: &copyState
    )
    defer { Darwin.close(parent.descriptor) }
    let destinationDescriptor = parent.basename.withCString { name in
      openat(
        parent.descriptor,
        name,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
        0o600
      )
    }
    guard destinationDescriptor >= 0 else {
      throw MCPClientSessionError.connectionClosed
    }
    var createdStatus = stat()
    guard
      fstat(destinationDescriptor, &createdStatus) == 0,
      createdStatus.st_mode & S_IFMT == S_IFREG,
      createdStatus.st_uid == geteuid(),
      createdStatus.st_nlink == 1
    else {
      Darwin.close(destinationDescriptor)
      throw MCPClientSessionError.connectionClosed
    }
    copyState.createdEntries.append(
      CreatedEntry(relativePath: destinationRelativePath, kind: .file, status: createdStatus)
    )
    do {
      beforeCopy?()
      try copyExactBytes(
        from: sourceDescriptor,
        to: destinationDescriptor,
        expectedByteCount: initialStatus.st_size
      )
      var finalSourceStatus = stat()
      let destinationMode: mode_t = initialStatus.st_mode & 0o111 == 0 ? 0o400 : 0o500
      guard
        fstat(sourceDescriptor, &finalSourceStatus) == 0,
        sameSourceIdentityAndMetadata(initialStatus, finalSourceStatus),
        fchmod(destinationDescriptor, destinationMode) == 0,
        fsync(destinationDescriptor) == 0
      else {
        throw MCPClientSessionError.connectionClosed
      }
      var destinationStatus = stat()
      guard
        fstat(destinationDescriptor, &destinationStatus) == 0,
        destinationStatus.st_mode & S_IFMT == S_IFREG,
        destinationStatus.st_uid == geteuid(),
        destinationStatus.st_nlink == 1,
        destinationStatus.st_size == initialStatus.st_size,
        destinationStatus.st_mode & 0o777 == destinationMode
      else {
        throw MCPClientSessionError.connectionClosed
      }
      copyState.totalByteCount = nextTotal
      copyState.copiedFiles.insert(destinationRelativePath)
      copyState.copiedFileSources[destinationRelativePath] = sourceRelativePath
      return (destinationDescriptor, destinationStatus)
    } catch {
      Darwin.close(destinationDescriptor)
      throw error
    }
  }

  private static func copySymbolicLink(
    name: String,
    initialStatus: stat,
    sourceParentDescriptor: Int32,
    sourceRelativePath: String,
    destinationRelativePath: String,
    sourcePackageRoot: String,
    destinationPackageRoot: String,
    destinationRootDescriptor: Int32,
    copyState: inout CopyState
  ) throws {
    guard
      initialStatus.st_uid == 0 || initialStatus.st_uid == geteuid(),
      initialStatus.st_nlink == 1,
      initialStatus.st_size > 0,
      initialStatus.st_size <= off_t(maximumSymbolicLinkBytes),
      canCreateBundleEntry(currentCount: copyState.createdEntries.count)
    else {
      throw MCPClientSessionError.connectionClosed
    }
    guard
      let nextTotal = nextBundleByteCount(
        current: copyState.totalByteCount,
        adding: initialStatus.st_size
      )
    else {
      throw MCPClientSessionError.connectionClosed
    }
    var targetBytes = [CChar](repeating: 0, count: maximumSymbolicLinkBytes + 1)
    let targetCount = name.withCString { childName in
      readlinkat(sourceParentDescriptor, childName, &targetBytes, maximumSymbolicLinkBytes)
    }
    guard targetCount > 0, targetCount < maximumSymbolicLinkBytes,
      off_t(targetCount) == initialStatus.st_size,
      let target = String(
        bytes: targetBytes.prefix(targetCount).map { UInt8(bitPattern: $0) },
        encoding: .utf8
      ),
      !target.hasPrefix("/"),
      let resolvedTarget = normalizeRelativePath(
        target,
        relativeTo: directoryPath(of: sourceRelativePath)
      ),
      resolvedTarget == sourcePackageRoot || resolvedTarget.hasPrefix(sourcePackageRoot + "/"),
      let destinationTarget = normalizeRelativePath(
        target,
        relativeTo: directoryPath(of: destinationRelativePath)
      ),
      destinationTarget == destinationPackageRoot
        || destinationTarget.hasPrefix(destinationPackageRoot + "/")
    else {
      throw MCPClientSessionError.connectionClosed
    }
    var finalStatus = stat()
    let finalStatusResult = name.withCString { childName in
      fstatat(sourceParentDescriptor, childName, &finalStatus, AT_SYMLINK_NOFOLLOW)
    }
    guard
      finalStatusResult == 0,
      sameSourceIdentityAndMetadata(initialStatus, finalStatus)
    else {
      throw MCPClientSessionError.connectionClosed
    }
    let parent = try destinationParent(
      for: destinationRelativePath,
      beneath: destinationRootDescriptor,
      copyState: &copyState
    )
    defer { Darwin.close(parent.descriptor) }
    let result = target.withCString { targetName in
      parent.basename.withCString { linkName in
        symlinkat(targetName, parent.descriptor, linkName)
      }
    }
    guard result == 0 else {
      throw MCPClientSessionError.connectionClosed
    }
    var createdStatus = stat()
    let createdStatusResult = parent.basename.withCString { linkName in
      fstatat(parent.descriptor, linkName, &createdStatus, AT_SYMLINK_NOFOLLOW)
    }
    guard
      createdStatusResult == 0,
      createdStatus.st_mode & S_IFMT == S_IFLNK,
      createdStatus.st_uid == geteuid()
    else {
      throw MCPClientSessionError.connectionClosed
    }
    copyState.createdEntries.append(
      CreatedEntry(
        relativePath: destinationRelativePath, kind: .symbolicLink, status: createdStatus)
    )
    copyState.totalByteCount = nextTotal
  }

  private static func copyExactBytes(
    from sourceDescriptor: Int32,
    to destinationDescriptor: Int32,
    expectedByteCount: off_t
  ) throws {
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    var offset = off_t(0)
    while offset < expectedByteCount {
      let remaining = expectedByteCount - offset
      let requested = min(buffer.count, Int(remaining))
      let count = buffer.withUnsafeMutableBytes { bytes in
        pread(sourceDescriptor, bytes.baseAddress, requested, offset)
      }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else {
        throw MCPClientSessionError.connectionClosed
      }
      try writeAll(buffer: buffer, count: count, descriptor: destinationDescriptor)
      offset += off_t(count)
    }

    var extraByte = UInt8(0)
    while true {
      let count = pread(sourceDescriptor, &extraByte, 1, expectedByteCount)
      if count < 0, errno == EINTR { continue }
      guard count == 0 else {
        throw MCPClientSessionError.connectionClosed
      }
      return
    }
  }

  private static func writeAll(
    buffer: [UInt8],
    count: Int,
    descriptor: Int32
  ) throws {
    var offset = 0
    while offset < count {
      let written = buffer.withUnsafeBytes { bytes in
        Darwin.write(
          descriptor,
          bytes.baseAddress?.advanced(by: offset),
          count - offset
        )
      }
      if written < 0, errno == EINTR { continue }
      guard written > 0 else {
        throw MCPClientSessionError.connectionClosed
      }
      offset += written
    }
  }
}
