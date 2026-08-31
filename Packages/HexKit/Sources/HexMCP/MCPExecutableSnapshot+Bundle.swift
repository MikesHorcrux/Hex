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
    guard let resolvedPath = try resolveFrameworkRelativePath(
      relativePath,
      packageRoot: packageRoot,
      beneath: rootDescriptor,
      missingIsAllowed: missingIsAllowed
    ) else {
      return nil
    }
    guard let file = try openSourceRegularFile(
      resolvedPath,
      beneath: rootDescriptor,
      requireExecutable: requireExecutable,
      missingIsAllowed: missingIsAllowed
    ) else {
      return nil
    }
    return (relativePath: resolvedPath, file: file)
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

  private static func resolveFrameworkRelativePath(
    _ relativePath: String,
    packageRoot: String,
    beneath rootDescriptor: Int32,
    missingIsAllowed: Bool
  ) throws -> String? {
    var currentPath = relativePath
    var visited = Set<String>()
    for _ in 0..<maximumSnapshotPathDepth {
      guard visited.insert(currentPath).inserted else {
        throw MCPClientSessionError.connectionClosed
      }
      guard let normalized = normalizeRelativePath(currentPath, relativeTo: ""),
        normalized == currentPath,
        normalized == packageRoot || normalized.hasPrefix(packageRoot + "/")
      else {
        throw MCPClientSessionError.connectionClosed
      }
      var descriptor = fcntl(rootDescriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
      guard descriptor >= 0 else {
        throw MCPClientSessionError.connectionClosed
      }
      var pathComponents = normalized.split(separator: "/").map(String.init)
      guard !pathComponents.isEmpty else {
        throw MCPClientSessionError.connectionClosed
      }
      var resolvedComponents: [String] = []
      var followedSymlink = false
      defer { Darwin.close(descriptor) }

      pathTraversal: for index in pathComponents.indices {
        let component = pathComponents[index]
        var componentStatus = stat()
        let statusResult = component.withCString { name in
          fstatat(descriptor, name, &componentStatus, AT_SYMLINK_NOFOLLOW)
        }
        guard statusResult == 0 else {
          let missing = errno == ENOENT || errno == ENOTDIR
          if missingIsAllowed && missing { return nil }
          throw MCPClientSessionError.connectionClosed
        }
        let componentPath = (resolvedComponents + [component]).joined(separator: "/")
        switch componentStatus.st_mode & S_IFMT {
        case S_IFLNK:
          guard
            componentStatus.st_uid == 0 || componentStatus.st_uid == geteuid(),
            componentStatus.st_nlink == 1,
            componentStatus.st_size > 0,
            componentStatus.st_size <= off_t(maximumSymbolicLinkBytes)
          else {
            throw MCPClientSessionError.connectionClosed
          }
          var targetBytes = [CChar](repeating: 0, count: maximumSymbolicLinkBytes + 1)
          let targetCount = component.withCString { name in
            readlinkat(descriptor, name, &targetBytes, maximumSymbolicLinkBytes)
          }
          guard
            targetCount > 0,
            targetCount < maximumSymbolicLinkBytes,
            off_t(targetCount) == componentStatus.st_size,
            let target = String(
              bytes: targetBytes.prefix(targetCount).map { UInt8(bitPattern: $0) },
              encoding: .utf8
            ),
            !target.hasPrefix("/"),
            let resolvedTarget = normalizeRelativePath(
              target,
              relativeTo: directoryPath(of: componentPath)
            ),
            resolvedTarget == packageRoot
              || resolvedTarget.hasPrefix(packageRoot + "/")
          else {
            throw MCPClientSessionError.connectionClosed
          }
          var finalStatus = stat()
          let finalStatusResult = component.withCString { name in
            fstatat(descriptor, name, &finalStatus, AT_SYMLINK_NOFOLLOW)
          }
          guard
            finalStatusResult == 0,
            sameSourceIdentityAndMetadata(componentStatus, finalStatus)
          else {
            throw MCPClientSessionError.connectionClosed
          }
          let remaining = pathComponents.dropFirst(index + 1).joined(separator: "/")
          currentPath = remaining.isEmpty
            ? resolvedTarget
            : resolvedTarget + "/" + remaining
          followedSymlink = true
          break pathTraversal
        case S_IFDIR:
          guard isAcceptableSourceDirectory(componentStatus) else {
            throw MCPClientSessionError.connectionClosed
          }
          guard index < pathComponents.index(before: pathComponents.endIndex) else {
            return currentPath
          }
          let nextDescriptor = component.withCString { name in
            openat(
              descriptor,
              name,
              O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
          }
          guard nextDescriptor >= 0 else {
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
          Darwin.close(descriptor)
          descriptor = nextDescriptor
          resolvedComponents.append(component)
        case S_IFREG:
          guard index == pathComponents.index(before: pathComponents.endIndex) else {
            throw MCPClientSessionError.connectionClosed
          }
          return currentPath
        default:
          throw MCPClientSessionError.connectionClosed
        }
      }
      if !followedSymlink {
        return currentPath
      }
    }
    throw MCPClientSessionError.connectionClosed
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
