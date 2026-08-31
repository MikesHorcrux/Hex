import Darwin
import Foundation

extension WorkspaceFileSystem {
  func combinedComponents(
    path: String,
    workingDirectory: URL?
  ) throws -> [String] {
    try validateRootIdentity()
    let relativePath = try WorkspaceRelativePath(path)
    let baseComponents = try workingDirectoryComponents(workingDirectory)
    let components = baseComponents + relativePath.components
    try validateComponents(components, error: .invalidPath)
    return components
  }

  func workingDirectoryComponents(_ workingDirectory: URL?) throws -> [String] {
    guard let workingDirectory else {
      return []
    }
    guard
      workingDirectory.isFileURL,
      workingDirectory.path.hasPrefix("/"),
      !workingDirectory.path.contains("\0")
    else {
      throw WorkspaceFileSystemError.invalidWorkingDirectory
    }
    let canonicalDirectory = workingDirectory.standardizedFileURL
    let rootComponents = rootURL.pathComponents
    let candidateComponents = canonicalDirectory.pathComponents
    guard
      candidateComponents.count >= rootComponents.count,
      Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    else {
      throw WorkspaceFileSystemError.invalidWorkingDirectory
    }
    let relativeComponents = Array(candidateComponents.dropFirst(rootComponents.count))
    guard relativeComponents.allSatisfy(WorkspacePathScalarPolicy.isPromptSafe) else {
      throw WorkspaceFileSystemError.invalidWorkingDirectory
    }
    try validateComponents(relativeComponents, error: .invalidWorkingDirectory)
    let descriptor: Int32
    do {
      descriptor = try openDirectory(components: relativeComponents)
    } catch {
      throw WorkspaceFileSystemError.invalidWorkingDirectory
    }
    Darwin.close(descriptor)
    return relativeComponents
  }

  func openDirectory(components: [String]) throws -> Int32 {
    try validateRootIdentity()
    try validateComponents(components, error: .invalidPath)
    var descriptor = fcntl(rootDescriptor, F_DUPFD_CLOEXEC, 0)
    guard descriptor >= 0 else {
      throw WorkspaceFileSystemError.ioFailure
    }
    do {
      for component in components {
        let status = try entryStatus(named: component, in: descriptor)
        guard status.st_mode & S_IFMT != S_IFLNK else {
          throw WorkspaceFileSystemError.symbolicLinkRejected
        }
        guard status.st_mode & S_IFMT == S_IFDIR else {
          throw WorkspaceFileSystemError.notDirectory
        }
        let nextDescriptor = openat(
          descriptor,
          component,
          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard nextDescriptor >= 0 else {
          throw mappedOpenError()
        }
        var openedStatus = stat()
        guard
          fstat(nextDescriptor, &openedStatus) == 0,
          openedStatus.st_mode & S_IFMT == S_IFDIR,
          openedStatus.st_dev == status.st_dev,
          openedStatus.st_ino == status.st_ino
        else {
          Darwin.close(nextDescriptor)
          throw WorkspaceFileSystemError.ioFailure
        }
        Darwin.close(descriptor)
        descriptor = nextDescriptor
      }
      return descriptor
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  func openRegularFile(components: [String]) throws -> Int32 {
    guard let name = components.last else {
      throw WorkspaceFileSystemError.notRegularFile
    }
    let parentDescriptor = try openDirectory(components: Array(components.dropLast()))
    defer { Darwin.close(parentDescriptor) }
    let status = try entryStatus(named: name, in: parentDescriptor)
    guard status.st_mode & S_IFMT != S_IFLNK else {
      throw WorkspaceFileSystemError.symbolicLinkRejected
    }
    guard status.st_mode & S_IFMT == S_IFREG else {
      throw WorkspaceFileSystemError.notRegularFile
    }
    let descriptor = openat(parentDescriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw mappedOpenError()
    }
    var openedStatus = stat()
    guard
      fstat(descriptor, &openedStatus) == 0,
      openedStatus.st_mode & S_IFMT == S_IFREG,
      openedStatus.st_dev == status.st_dev,
      openedStatus.st_ino == status.st_ino
    else {
      Darwin.close(descriptor)
      throw WorkspaceFileSystemError.notRegularFile
    }
    guard openedStatus.st_nlink == 1 else {
      Darwin.close(descriptor)
      throw WorkspaceFileSystemError.hardLinkRejected
    }
    return descriptor
  }

  func entryStatus(named name: String, in directoryDescriptor: Int32) throws -> stat {
    var status = stat()
    guard fstatat(directoryDescriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
      if errno == ENOENT {
        throw WorkspaceFileSystemError.notFound
      }
      throw WorkspaceFileSystemError.ioFailure
    }
    return status
  }

  func mappedOpenError() -> WorkspaceFileSystemError {
    switch errno {
    case ENOENT:
      return .notFound
    case ENOTDIR:
      return .notDirectory
    case ELOOP:
      return .symbolicLinkRejected
    default:
      return .ioFailure
    }
  }

  func displayPath(_ components: [String]) -> String {
    components.isEmpty ? "." : components.joined(separator: "/")
  }

  func validateComponents(
    _ components: [String],
    error: WorkspaceFileSystemError
  ) throws {
    guard components.count <= 256 else {
      throw error
    }
    var byteCount = 0
    for component in components {
      guard
        !component.isEmpty,
        component != ".",
        component != "..",
        component.utf8.count <= 255,
        !component.contains("/"),
        !component.contains("\0")
      else {
        throw error
      }
      let separatorBytes = byteCount == 0 ? 0 : 1
      let (withSeparator, separatorOverflowed) = byteCount.addingReportingOverflow(
        separatorBytes
      )
      let (candidateBytes, componentOverflowed) = withSeparator.addingReportingOverflow(
        component.utf8.count
      )
      guard !separatorOverflowed, !componentOverflowed, candidateBytes <= 4_096 else {
        throw error
      }
      byteCount = candidateBytes
    }
  }

  func validateRootIdentity() throws {
    var pathStatus = stat()
    guard
      lstat(rootURL.path, &pathStatus) == 0,
      pathStatus.st_mode & S_IFMT == S_IFDIR,
      UInt64(pathStatus.st_dev) == rootDevice,
      UInt64(pathStatus.st_ino) == rootInode
    else {
      throw WorkspaceFileSystemError.invalidRoot
    }
    var descriptorStatus = stat()
    guard
      fstat(rootDescriptor, &descriptorStatus) == 0,
      descriptorStatus.st_mode & S_IFMT == S_IFDIR,
      UInt64(descriptorStatus.st_dev) == rootDevice,
      UInt64(descriptorStatus.st_ino) == rootInode
    else {
      throw WorkspaceFileSystemError.invalidRoot
    }
  }

  func authorizationResource(
    path: String,
    workingDirectory: URL?
  ) throws -> String {
    let components = try combinedComponents(path: path, workingDirectory: workingDirectory)
    return components.reduce(rootURL) { partialURL, component in
      partialURL.appending(path: component)
    }.path
  }
}
