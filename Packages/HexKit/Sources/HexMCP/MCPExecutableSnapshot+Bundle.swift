import Darwin
import Foundation

extension MCPExecutableSnapshot {
  static func createBundleSnapshot(
    layout: BundleLayout,
    sourceDescriptor: Int32,
    initialStatus: stat,
    destination: PrivateDirectory,
    copyState: inout CopyState,
    afterSourceValidation: (@Sendable (_ snapshotPath: String) -> Void)?
  ) throws -> (descriptor: Int32, status: stat) {
    let sourceRootDescriptor = Darwin.open(
      layout.rootPath,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard sourceRootDescriptor >= 0 else {
      throw MCPClientSessionError.connectionClosed
    }
    defer { Darwin.close(sourceRootDescriptor) }
    var initialRootStatus = stat()
    guard
      fstat(sourceRootDescriptor, &initialRootStatus) == 0,
      isAcceptableSourceDirectory(initialRootStatus)
    else {
      throw MCPClientSessionError.connectionClosed
    }
    guard
      let boundExecutable = try openSourceRegularFile(
        layout.executableRelativePath,
        beneath: sourceRootDescriptor,
        requireExecutable: true,
        missingIsAllowed: false
      )
    else {
      throw MCPClientSessionError.connectionClosed
    }
    guard sameSourceIdentityAndMetadata(initialStatus, boundExecutable.status) else {
      Darwin.close(boundExecutable.descriptor)
      throw MCPClientSessionError.connectionClosed
    }
    Darwin.close(boundExecutable.descriptor)

    let executable = try copyRegularFile(
      sourceDescriptor: sourceDescriptor,
      initialStatus: initialStatus,
      sourceRelativePath: layout.executableRelativePath,
      destinationRelativePath: layout.executableRelativePath,
      destinationRootDescriptor: destination.descriptor,
      requireExecutable: true,
      copyState: &copyState,
      beforeCopy: {
        afterSourceValidation?(destination.path + "/" + layout.executableRelativePath)
      }
    )
    do {
      if let image = try readDestinationImage(
        layout.executableRelativePath,
        beneath: destination.descriptor
      ) {
        try copyDependencyClosure(
          initialImage: ImageRecord(
            sourceRelativePath: layout.executableRelativePath,
            snapshotRelativePath: layout.executableRelativePath,
            image: image,
            sourceInheritedRunpaths: [],
            snapshotInheritedRunpaths: []
          ),
          layout: layout,
          sourceRootDescriptor: sourceRootDescriptor,
          destinationRootDescriptor: destination.descriptor,
          copyState: &copyState
        )
      }
      var finalRootStatus = stat()
      guard
        fstat(sourceRootDescriptor, &finalRootStatus) == 0,
        sameSourceIdentityAndMetadata(initialRootStatus, finalRootStatus)
      else {
        throw MCPClientSessionError.connectionClosed
      }
      return executable
    } catch {
      throw error
    }
  }

  private static func copyDependencyClosure(
    initialImage: ImageRecord,
    layout: BundleLayout,
    sourceRootDescriptor: Int32,
    destinationRootDescriptor: Int32,
    copyState: inout CopyState
  ) throws {
    var images = [initialImage]
    var scannedImages: Set<String> = [initialImage.snapshotRelativePath]
    var imageIndex = 0
    while imageIndex < images.count {
      guard isAcceptableBundleImageCount(images.count) else {
        throw MCPClientSessionError.connectionClosed
      }
      let image = images[imageIndex]
      imageIndex += 1
      let sourceSearchRunpaths = try expandedRunpaths(
        image.image.runpaths,
        inherited: image.sourceInheritedRunpaths,
        imageDirectory: directoryPath(of: image.sourceRelativePath),
        executableDirectory: directoryPath(of: initialImage.sourceRelativePath),
        layout: layout,
        allowAbsoluteBundlePath: true
      )
      let snapshotSearchRunpaths = try expandedRunpaths(
        image.image.runpaths,
        inherited: image.snapshotInheritedRunpaths,
        imageDirectory: directoryPath(of: image.snapshotRelativePath),
        executableDirectory: directoryPath(of: initialImage.snapshotRelativePath),
        layout: layout,
        allowAbsoluteBundlePath: false
      )
      try copyState.admitRunpathBudget(
        source: sourceSearchRunpaths,
        snapshot: snapshotSearchRunpaths
      )
      for dependency in image.image.dependencies {
        guard
          let resolvedDependency = try resolveDependency(
            dependency,
            sourceImagePath: image.sourceRelativePath,
            snapshotImagePath: image.snapshotRelativePath,
            sourceSearchRunpaths: sourceSearchRunpaths,
            snapshotSearchRunpaths: snapshotSearchRunpaths,
            sourceExecutablePath: initialImage.sourceRelativePath,
            snapshotExecutablePath: initialImage.snapshotRelativePath,
            sourceRootDescriptor: sourceRootDescriptor
          )
        else {
          continue
        }
        let sourcePath = resolvedDependency.sourceRelativePath
        let snapshotPath = resolvedDependency.snapshotRelativePath
        do {
          if let copiedSource = copyState.copiedFileSources[snapshotPath] {
            guard copiedSource == sourcePath else {
              throw MCPClientSessionError.connectionClosed
            }
          } else if let sourcePackagePath = frameworkPackagePath(containing: sourcePath),
            let snapshotPackagePath = frameworkPackagePath(containing: snapshotPath)
          {
            guard
              sourcePath.dropFirst(sourcePackagePath.count)
                == snapshotPath.dropFirst(snapshotPackagePath.count)
            else {
              throw MCPClientSessionError.connectionClosed
            }
            if let copiedSourcePackage = copyState.copiedPackages[snapshotPackagePath] {
              guard copiedSourcePackage == sourcePackagePath else {
                throw MCPClientSessionError.connectionClosed
              }
            } else {
              try copySourceDirectoryTree(
                sourceRelativePath: sourcePackagePath,
                destinationRelativePath: snapshotPackagePath,
                boundDependency: resolvedDependency,
                sourceRootDescriptor: sourceRootDescriptor,
                destinationRootDescriptor: destinationRootDescriptor,
                copyState: &copyState
              )
              copyState.copiedPackages[snapshotPackagePath] = sourcePackagePath
            }
          } else {
            let copied = try copyRegularFile(
              sourceDescriptor: resolvedDependency.descriptor,
              initialStatus: resolvedDependency.status,
              sourceRelativePath: sourcePath,
              destinationRelativePath: snapshotPath,
              destinationRootDescriptor: destinationRootDescriptor,
              requireExecutable: false,
              copyState: &copyState,
              beforeCopy: nil
            )
            _ = copied
          }
          Darwin.close(resolvedDependency.descriptor)
        } catch {
          Darwin.close(resolvedDependency.descriptor)
          throw error
        }
        guard copyState.copiedFileSources[snapshotPath] == sourcePath else {
          throw MCPClientSessionError.connectionClosed
        }
        if scannedImages.insert(snapshotPath).inserted {
          guard
            let dependencyImage = try readDestinationImage(
              snapshotPath,
              beneath: destinationRootDescriptor
            )
          else {
            throw MCPClientSessionError.connectionClosed
          }
          images.append(
            ImageRecord(
              sourceRelativePath: sourcePath,
              snapshotRelativePath: snapshotPath,
              image: dependencyImage,
              sourceInheritedRunpaths: sourceSearchRunpaths,
              snapshotInheritedRunpaths: snapshotSearchRunpaths
            )
          )
        }
      }
    }
  }

  private static func resolveDependency(
    _ dependency: MCPMachOImage.Dependency,
    sourceImagePath: String,
    snapshotImagePath: String,
    sourceSearchRunpaths: [ExpandedRunpath],
    snapshotSearchRunpaths: [ExpandedRunpath],
    sourceExecutablePath: String,
    snapshotExecutablePath: String,
    sourceRootDescriptor: Int32
  ) throws -> ResolvedDependency? {
    if dependency.path.hasPrefix("/") {
      if isTrustedSystemPath(dependency.path) { return nil }
      throw MCPClientSessionError.connectionClosed
    }

    if dependency.path.hasPrefix("@rpath/") {
      let suffix = String(dependency.path.dropFirst("@rpath/".count))
      var snapshotPath: String?
      var externalPathPrecedesSnapshotPath = false
      for expanded in snapshotSearchRunpaths {
        if expanded.isExternalPath {
          if snapshotPath == nil { externalPathPrecedesSnapshotPath = true }
          if snapshotPath == nil, dependency.isRequired {
            throw MCPClientSessionError.connectionClosed
          }
          continue
        }
        if expanded.isTrustedSystemPath {
          let candidate =
            ((expanded.relativePath as NSString).appendingPathComponent(suffix)
            as NSString).standardizingPath
          guard isTrustedSystemPath(candidate) else {
            throw MCPClientSessionError.connectionClosed
          }
          continue
        }
        guard let candidate = normalizeRelativePath(suffix, relativeTo: expanded.relativePath)
        else {
          throw MCPClientSessionError.connectionClosed
        }
        if snapshotPath == nil { snapshotPath = candidate }
      }

      for expanded in sourceSearchRunpaths {
        if expanded.isExternalPath {
          continue
        }
        if expanded.isTrustedSystemPath {
          let candidate =
            ((expanded.relativePath as NSString).appendingPathComponent(suffix)
            as NSString).standardizingPath
          guard isTrustedSystemPath(candidate) else {
            throw MCPClientSessionError.connectionClosed
          }
          continue
        }
        guard let sourcePath = normalizeRelativePath(suffix, relativeTo: expanded.relativePath)
        else {
          throw MCPClientSessionError.connectionClosed
        }
        if let source = try openRuntimeDependencyFile(
          sourcePath,
          beneath: sourceRootDescriptor,
          requireExecutable: false,
          missingIsAllowed: true
        ) {
          guard let snapshotPath, !externalPathPrecedesSnapshotPath else {
            Darwin.close(source.file.descriptor)
            throw MCPClientSessionError.connectionClosed
          }
          let resolvedSnapshotPath = try mappedSnapshotPath(
            for: source.relativePath,
            sourceCandidate: sourcePath,
            snapshotCandidate: snapshotPath
          )
          return ResolvedDependency(
            sourceRelativePath: source.relativePath,
            snapshotRelativePath: resolvedSnapshotPath,
            descriptor: source.file.descriptor,
            status: source.file.status
          )
        }
      }

      if dependency.isRequired { throw MCPClientSessionError.connectionClosed }
      return nil
    }

    let sourceBasePath: String
    let snapshotBasePath: String
    let token: String
    if dependency.path == "@loader_path"
      || dependency.path.hasPrefix("@loader_path/")
    {
      sourceBasePath = directoryPath(of: sourceImagePath)
      snapshotBasePath = directoryPath(of: snapshotImagePath)
      token = "@loader_path"
    } else if dependency.path == "@executable_path"
      || dependency.path.hasPrefix("@executable_path/")
    {
      sourceBasePath = directoryPath(of: sourceExecutablePath)
      snapshotBasePath = directoryPath(of: snapshotExecutablePath)
      token = "@executable_path"
    } else {
      throw MCPClientSessionError.connectionClosed
    }

    let suffix = String(dependency.path.dropFirst(token.count))
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard
      let sourcePath = normalizeRelativePath(suffix, relativeTo: sourceBasePath),
      let snapshotPath = normalizeRelativePath(suffix, relativeTo: snapshotBasePath)
    else {
      throw MCPClientSessionError.connectionClosed
    }
    if let source = try openRuntimeDependencyFile(
      sourcePath,
      beneath: sourceRootDescriptor,
      requireExecutable: false,
      missingIsAllowed: true
    ) {
      let resolvedSnapshotPath = try mappedSnapshotPath(
        for: source.relativePath,
        sourceCandidate: sourcePath,
        snapshotCandidate: snapshotPath
      )
      return ResolvedDependency(
        sourceRelativePath: source.relativePath,
        snapshotRelativePath: resolvedSnapshotPath,
        descriptor: source.file.descriptor,
        status: source.file.status
      )
    }
    if dependency.isRequired { throw MCPClientSessionError.connectionClosed }
    return nil
  }

  private static func openRuntimeDependencyFile(
    _ relativePath: String,
    beneath rootDescriptor: Int32,
    requireExecutable: Bool,
    missingIsAllowed: Bool
  ) throws -> (
    relativePath: String,
    file: (descriptor: Int32, status: stat)
  )? {
    guard let normalized = normalizeRelativePath(relativePath, relativeTo: ""),
      normalized == relativePath
    else {
      throw MCPClientSessionError.connectionClosed
    }
    guard let packageRoot = frameworkPackagePath(containing: relativePath) else {
      guard let file = try openSourceRegularFile(
        relativePath,
        beneath: rootDescriptor,
        requireExecutable: requireExecutable,
        missingIsAllowed: missingIsAllowed
      ) else {
        return nil
      }
      return (relativePath: relativePath, file: file)
    }
    guard let basename = normalized.split(separator: "/").last.map(String.init) else {
      throw MCPClientSessionError.connectionClosed
    }
    let parentPath = normalized.split(separator: "/").dropLast().joined(separator: "/")
    guard parentPath == packageRoot || parentPath.hasPrefix(packageRoot + "/") else {
      throw MCPClientSessionError.connectionClosed
    }
    guard let resolved = try resolveFrameworkRelativePath(
      parentPath: parentPath,
      target: basename,
      packageRoot: packageRoot,
      beneath: rootDescriptor,
      expectedParentDescriptor: nil,
      requireExecutable: requireExecutable,
      requireRegular: true,
      missingIsAllowed: missingIsAllowed
    ) else {
      return nil
    }
    return (
      relativePath: resolved.relativePath,
      file: (descriptor: resolved.descriptor, status: resolved.status)
    )
  }

  private static func mappedSnapshotPath(
    for resolvedSourcePath: String,
    sourceCandidate: String,
    snapshotCandidate: String
  ) throws -> String {
    let sourcePackagePath = frameworkPackagePath(containing: sourceCandidate)
    let resolvedSourcePackagePath = frameworkPackagePath(containing: resolvedSourcePath)
    let snapshotPackagePath = frameworkPackagePath(containing: snapshotCandidate)
    if sourcePackagePath == nil,
      resolvedSourcePackagePath == nil,
      snapshotPackagePath == nil
    {
      return snapshotCandidate
    }
    guard let sourcePackagePath,
      let resolvedSourcePackagePath,
      let snapshotPackagePath,
      resolvedSourcePackagePath == sourcePackagePath,
      resolvedSourcePath == resolvedSourcePackagePath
        || resolvedSourcePath.hasPrefix(resolvedSourcePackagePath + "/")
    else {
      throw MCPClientSessionError.connectionClosed
    }
    let sourceSuffix = resolvedSourcePath.dropFirst(resolvedSourcePackagePath.count)
    guard
      sourceCandidate == sourcePackagePath
        || sourceCandidate.hasPrefix(sourcePackagePath + "/"),
      snapshotCandidate == snapshotPackagePath
        || snapshotCandidate.hasPrefix(snapshotPackagePath + "/"),
      sourceSuffix.isEmpty || sourceSuffix.first == "/"
    else {
      throw MCPClientSessionError.connectionClosed
    }
    return snapshotPackagePath + String(sourceSuffix)
  }

  static func resolveFrameworkRelativePath(
    parentPath: String,
    target: String,
    packageRoot: String,
    beneath rootDescriptor: Int32,
    expectedParentDescriptor: Int32?,
    requireExecutable: Bool,
    requireRegular: Bool,
    missingIsAllowed: Bool
  ) throws -> (relativePath: String, descriptor: Int32, status: stat)? {
    guard
      let normalizedParent = normalizeRelativePath(parentPath, relativeTo: ""),
      normalizedParent == parentPath,
      normalizedParent == packageRoot || normalizedParent.hasPrefix(packageRoot + "/"),
      !target.hasPrefix("/"),
      !target.contains("\0"),
      target.utf8.count <= maximumSymbolicLinkBytes
    else {
      throw MCPClientSessionError.connectionClosed
    }
    let packageComponents = packageRoot.split(separator: "/").map(String.init)
    let parentComponents = normalizedParent.split(separator: "/").map(String.init)
    guard parentComponents.starts(with: packageComponents) else {
      throw MCPClientSessionError.connectionClosed
    }
    let parentSuffix = Array(parentComponents.dropFirst(packageComponents.count))
    var targetComponents = target.split(separator: "/", omittingEmptySubsequences: true)
      .map(String.init)
      .filter { $0 != "." }
    guard !target.isEmpty else {
      throw MCPClientSessionError.connectionClosed
    }
    if targetComponents.isEmpty { targetComponents = ["."] }

    guard
      let packageDescriptor = try openSourceDirectory(
        packageRoot,
        beneath: rootDescriptor,
        missingIsAllowed: missingIsAllowed
      )
    else {
      return nil
    }
    var directoryDescriptors = [packageDescriptor]
    var directoryPaths = [packageRoot]
    var symlinkBindings: [FrameworkSymlinkBinding] = []
    var visitedSymlinks = Set<String>()
    var pendingComponents = parentSuffix + targetComponents
    var componentIndex = 0
    var processedParentComponents = 0
    var atTargetBoundary = expectedParentDescriptor == nil
    var followedSymlinkCount = 0
    var expectedParentStatus: stat?
    defer {
      for descriptor in directoryDescriptors { Darwin.close(descriptor) }
      for binding in symlinkBindings { Darwin.close(binding.parentDescriptor) }
    }
    if let expectedParentDescriptor {
      var status = stat()
      guard
        fstat(expectedParentDescriptor, &status) == 0,
        isAcceptableSourceDirectory(status)
      else {
        throw MCPClientSessionError.connectionClosed
      }
      expectedParentStatus = status
      if parentSuffix.isEmpty {
        var packageStatus = stat()
        guard
          fstat(packageDescriptor, &packageStatus) == 0,
          sameSourceIdentityAndMetadata(status, packageStatus)
        else {
          throw MCPClientSessionError.connectionClosed
        }
        atTargetBoundary = true
      }
    }

    while true {
      if !atTargetBoundary && processedParentComponents == parentSuffix.count {
        var currentStatus = stat()
        guard
          let expectedParentStatus,
          let currentDescriptor = directoryDescriptors.last,
          fstat(currentDescriptor, &currentStatus) == 0,
          sameSourceIdentityAndMetadata(expectedParentStatus, currentStatus)
        else {
          throw MCPClientSessionError.connectionClosed
        }
        atTargetBoundary = true
      }
      guard componentIndex < pendingComponents.count else {
        guard atTargetBoundary, !requireRegular else {
          throw MCPClientSessionError.connectionClosed
        }
        guard let currentDescriptor = directoryDescriptors.last,
          let currentPath = directoryPaths.last
        else {
          throw MCPClientSessionError.connectionClosed
        }
        let descriptor = fcntl(
          currentDescriptor,
          F_DUPFD_CLOEXEC,
          STDERR_FILENO + 1
        )
        guard descriptor >= 0 else {
          throw MCPClientSessionError.connectionClosed
        }
        var status = stat()
        guard
          fstat(descriptor, &status) == 0,
          isAcceptableSourceDirectory(status)
        else {
          Darwin.close(descriptor)
          throw MCPClientSessionError.connectionClosed
        }
        do {
          try revalidateFrameworkSymlinkBindings(symlinkBindings)
        } catch {
          Darwin.close(descriptor)
          throw error
        }
        return (currentPath, descriptor, status)
      }

      let component = pendingComponents[componentIndex]
      componentIndex += 1
      if component.isEmpty || component == "." { continue }
      if component == ".." {
        guard atTargetBoundary, directoryDescriptors.count > 1 else {
          throw MCPClientSessionError.connectionClosed
        }
        Darwin.close(directoryDescriptors.removeLast())
        directoryPaths.removeLast()
        continue
      }
      guard !component.contains("/"), !component.contains("\0"), component.utf8.count <= 255 else {
        throw MCPClientSessionError.connectionClosed
      }
      guard
        let currentDescriptor = directoryDescriptors.last,
        let currentPath = directoryPaths.last
      else {
        throw MCPClientSessionError.connectionClosed
      }
      var componentStatus = stat()
      let statusResult = component.withCString { name in
        fstatat(currentDescriptor, name, &componentStatus, AT_SYMLINK_NOFOLLOW)
      }
      guard statusResult == 0 else {
        if missingIsAllowed && (errno == ENOENT || errno == ENOTDIR) { return nil }
        throw MCPClientSessionError.connectionClosed
      }
      switch componentStatus.st_mode & S_IFMT {
      case S_IFLNK:
        guard atTargetBoundary else {
          throw MCPClientSessionError.connectionClosed
        }
        let linkTarget = try readFrameworkSymlink(
          name: component,
          descriptor: currentDescriptor,
          status: componentStatus
        )
        let linkIdentity = "\(componentStatus.st_dev):\(componentStatus.st_ino)"
        guard visitedSymlinks.insert(linkIdentity).inserted else {
          throw MCPClientSessionError.connectionClosed
        }
        let parentDuplicate = fcntl(
          currentDescriptor,
          F_DUPFD_CLOEXEC,
          STDERR_FILENO + 1
        )
        guard parentDuplicate >= 0 else {
          throw MCPClientSessionError.connectionClosed
        }
        var finalLinkStatus = stat()
        let finalStatusResult = component.withCString { name in
          fstatat(currentDescriptor, name, &finalLinkStatus, AT_SYMLINK_NOFOLLOW)
        }
        guard
          finalStatusResult == 0,
          sameSourceIdentityAndMetadata(componentStatus, finalLinkStatus)
        else {
          Darwin.close(parentDuplicate)
          throw MCPClientSessionError.connectionClosed
        }
        let finalLinkTarget: String
        do {
          finalLinkTarget = try readFrameworkSymlink(
            name: component,
            descriptor: currentDescriptor,
            status: finalLinkStatus
          )
        } catch {
          Darwin.close(parentDuplicate)
          throw error
        }
        guard finalLinkTarget == linkTarget else {
          Darwin.close(parentDuplicate)
          throw MCPClientSessionError.connectionClosed
        }
        symlinkBindings.append(
          FrameworkSymlinkBinding(
            parentDescriptor: parentDuplicate,
            name: component,
            status: componentStatus,
            target: linkTarget
          )
        )
        followedSymlinkCount += 1
        guard followedSymlinkCount <= maximumSnapshotPathDepth else {
          throw MCPClientSessionError.connectionClosed
        }
        let remaining = Array(pendingComponents[componentIndex...])
        pendingComponents = linkTarget
          .split(separator: "/", omittingEmptySubsequences: true)
          .map(String.init)
          .filter { $0 != "." } + remaining
        if pendingComponents.isEmpty { pendingComponents = ["."] }
        componentIndex = 0
      case S_IFDIR:
        guard isAcceptableSourceDirectory(componentStatus) else {
          throw MCPClientSessionError.connectionClosed
        }
        if componentIndex == pendingComponents.count {
          guard !requireRegular else {
            throw MCPClientSessionError.connectionClosed
          }
        }
        let path = currentPath + "/" + component
        guard
          let normalizedPath = normalizeRelativePath(path, relativeTo: ""),
          normalizedPath == path
        else {
          throw MCPClientSessionError.connectionClosed
        }
        let nextDescriptor = component.withCString { name in
          openat(
            currentDescriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
          )
        }
        guard nextDescriptor >= 0 else {
          if missingIsAllowed && (errno == ENOENT || errno == ENOTDIR) { return nil }
          throw MCPClientSessionError.connectionClosed
        }
        var openedStatus = stat()
        guard
          fstat(nextDescriptor, &openedStatus) == 0,
          sameSourceIdentityAndMetadata(componentStatus, openedStatus)
        else {
          Darwin.close(nextDescriptor)
          throw MCPClientSessionError.connectionClosed
        }
        directoryDescriptors.append(nextDescriptor)
        directoryPaths.append(path)
        if !atTargetBoundary { processedParentComponents += 1 }
      case S_IFREG:
        guard atTargetBoundary, componentIndex == pendingComponents.count else {
          throw MCPClientSessionError.connectionClosed
        }
        let descriptor = component.withCString { name in
          openat(
            currentDescriptor,
            name,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
          )
        }
        guard descriptor >= 0 else {
          if missingIsAllowed && (errno == ENOENT || errno == ENOTDIR) { return nil }
          throw MCPClientSessionError.connectionClosed
        }
        var status = stat()
        guard
          fstat(descriptor, &status) == 0,
          sameSourceIdentityAndMetadata(componentStatus, status),
          isAcceptableRuntimeSource(status, requireExecutable: requireExecutable)
        else {
          Darwin.close(descriptor)
          throw MCPClientSessionError.connectionClosed
        }
        let path = currentPath + "/" + component
        guard
          let normalizedPath = normalizeRelativePath(path, relativeTo: ""),
          normalizedPath == path
        else {
          Darwin.close(descriptor)
          throw MCPClientSessionError.connectionClosed
        }
        do {
          try revalidateFrameworkSymlinkBindings(symlinkBindings)
        } catch {
          Darwin.close(descriptor)
          throw error
        }
        return (path, descriptor, status)
      default:
        throw MCPClientSessionError.connectionClosed
      }
    }
  }

  private static func readFrameworkSymlink(
    name: String,
    descriptor: Int32,
    status: stat
  ) throws -> String {
    guard
      status.st_mode & S_IFMT == S_IFLNK,
      status.st_uid == 0 || status.st_uid == geteuid(),
      status.st_nlink == 1,
      status.st_size > 0,
      status.st_size <= off_t(maximumSymbolicLinkBytes)
    else {
      throw MCPClientSessionError.connectionClosed
    }
    var targetBytes = [CChar](repeating: 0, count: maximumSymbolicLinkBytes + 1)
    let targetCount = name.withCString { linkName in
      readlinkat(descriptor, linkName, &targetBytes, maximumSymbolicLinkBytes)
    }
    guard
      targetCount > 0,
      targetCount < maximumSymbolicLinkBytes,
      off_t(targetCount) == status.st_size,
      let target = String(
        bytes: targetBytes.prefix(targetCount).map { UInt8(bitPattern: $0) },
        encoding: .utf8
      ),
      !target.hasPrefix("/"),
      !target.contains("\0")
    else {
      throw MCPClientSessionError.connectionClosed
    }
    return target
  }

  private static func revalidateFrameworkSymlinkBindings(
    _ bindings: [FrameworkSymlinkBinding]
  ) throws {
    for binding in bindings {
      var currentStatus = stat()
      let result = binding.name.withCString { name in
        fstatat(
          binding.parentDescriptor,
          name,
          &currentStatus,
          AT_SYMLINK_NOFOLLOW
        )
      }
      guard
        result == 0,
        sameSourceIdentityAndMetadata(binding.status, currentStatus)
      else {
        throw MCPClientSessionError.connectionClosed
      }
      guard try readFrameworkSymlink(
        name: binding.name,
        descriptor: binding.parentDescriptor,
        status: currentStatus
      ) == binding.target else {
        throw MCPClientSessionError.connectionClosed
      }
    }
  }

  private static func expandedRunpaths(
    _ runpaths: [String],
    inherited: [ExpandedRunpath],
    imageDirectory: String,
    executableDirectory: String,
    layout: BundleLayout,
    allowAbsoluteBundlePath: Bool
  ) throws -> [ExpandedRunpath] {
    var result: [ExpandedRunpath] = []
    var seen = Set<ExpandedRunpath>()
    var byteCount = Int64(0)
    for runpath in runpaths {
      if let expanded = expandRunpath(
        runpath,
        imageDirectory: imageDirectory,
        executableDirectory: executableDirectory,
        layout: layout,
        allowAbsoluteBundlePath: allowAbsoluteBundlePath
      ), seen.insert(expanded).inserted {
        try appendRunpath(expanded, to: &result, byteCount: &byteCount)
      }
    }
    for expanded in inherited where seen.insert(expanded).inserted {
      try appendRunpath(expanded, to: &result, byteCount: &byteCount)
    }
    return result
  }

  private static func appendRunpath(
    _ runpath: ExpandedRunpath,
    to result: inout [ExpandedRunpath],
    byteCount: inout Int64
  ) throws {
    let (nextByteCount, overflowed) = byteCount.addingReportingOverflow(
      Int64(runpath.relativePath.utf8.count)
    )
    guard
      result.count < MCPExecutableSnapshot.maximumRunpathsPerImage,
      !overflowed,
      nextByteCount <= Int64(MCPExecutableSnapshot.maximumRunpathBytesPerImage)
    else {
      throw MCPClientSessionError.limitExceeded
    }
    result.append(runpath)
    byteCount = nextByteCount
  }

  private static func expandRunpath(
    _ runpath: String,
    imageDirectory: String,
    executableDirectory: String,
    layout: BundleLayout,
    allowAbsoluteBundlePath: Bool
  ) -> ExpandedRunpath? {
    if runpath.hasPrefix("/") {
      if isTrustedSystemPath(runpath) {
        return ExpandedRunpath(
          relativePath: runpath,
          isTrustedSystemPath: true,
          isExternalPath: false
        )
      }
      let rootPrefix = layout.rootPath + "/"
      guard allowAbsoluteBundlePath, runpath.hasPrefix(rootPrefix) else {
        return ExpandedRunpath(
          relativePath: runpath,
          isTrustedSystemPath: false,
          isExternalPath: true
        )
      }
      let relativePath = String(runpath.dropFirst(rootPrefix.count))
      guard let normalized = normalizeRelativePath(relativePath, relativeTo: "") else {
        return ExpandedRunpath(
          relativePath: runpath,
          isTrustedSystemPath: false,
          isExternalPath: true
        )
      }
      return ExpandedRunpath(
        relativePath: normalized,
        isTrustedSystemPath: false,
        isExternalPath: false
      )
    }
    if runpath == "@loader_path" || runpath.hasPrefix("@loader_path/") {
      let suffix = String(runpath.dropFirst("@loader_path".count))
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      guard let normalized = normalizeRelativePath(suffix, relativeTo: imageDirectory) else {
        return ExpandedRunpath(
          relativePath: runpath,
          isTrustedSystemPath: false,
          isExternalPath: true
        )
      }
      return ExpandedRunpath(
        relativePath: normalized,
        isTrustedSystemPath: false,
        isExternalPath: false
      )
    }
    if runpath == "@executable_path" || runpath.hasPrefix("@executable_path/") {
      let suffix = String(runpath.dropFirst("@executable_path".count))
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      guard let normalized = normalizeRelativePath(suffix, relativeTo: executableDirectory) else {
        return ExpandedRunpath(
          relativePath: runpath,
          isTrustedSystemPath: false,
          isExternalPath: true
        )
      }
      return ExpandedRunpath(
        relativePath: normalized,
        isTrustedSystemPath: false,
        isExternalPath: false
      )
    }
    return ExpandedRunpath(
      relativePath: runpath,
      isTrustedSystemPath: false,
      isExternalPath: true
    )
  }

  static func bundleLayout(for sourcePath: String) -> BundleLayout? {
    guard sourcePath.hasPrefix("/"), !sourcePath.contains("\0") else { return nil }
    let standardizedPath = (sourcePath as NSString).standardizingPath
    let components = (standardizedPath as NSString).pathComponents
    guard let bundleIndex = components.lastIndex(where: { $0.hasSuffix(".app") }),
      bundleIndex < components.count - 1
    else {
      return nil
    }
    let rootPath = NSString.path(withComponents: Array(components[...bundleIndex]))
    let executableRelativePath = components[(bundleIndex + 1)...].joined(separator: "/")
    guard let normalized = normalizeRelativePath(executableRelativePath, relativeTo: ""),
      normalized == executableRelativePath
    else {
      return nil
    }
    return BundleLayout(rootPath: rootPath, executableRelativePath: executableRelativePath)
  }

  private static func frameworkPackagePath(containing relativePath: String) -> String? {
    let components = relativePath.split(separator: "/").map(String.init)
    guard let index = components.lastIndex(where: { $0.hasSuffix(".framework") }) else {
      return nil
    }
    return components[...index].joined(separator: "/")
  }
}
