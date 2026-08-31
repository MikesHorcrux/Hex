import Darwin
import Foundation

public actor WorkspaceFileSystem {
  let rootURL: URL
  let rootDescriptor: Int32
  let rootDevice: UInt64
  let rootInode: UInt64
  let configuration: WorkspaceFileSystemConfiguration
  let replacementPublicationHook: (@Sendable () throws -> Void)?

  public init(
    root: URL,
    configuration: WorkspaceFileSystemConfiguration = .standard
  ) throws {
    try self.init(
      root: root,
      configuration: configuration,
      replacementPublicationHook: nil
    )
  }

  init(
    root: URL,
    configuration: WorkspaceFileSystemConfiguration = .standard,
    replacementPublicationHook: (@Sendable () throws -> Void)?
  ) throws {
    guard root.isFileURL, root.path.hasPrefix("/"), !root.path.contains("\0") else {
      throw WorkspaceFileSystemError.invalidRoot
    }
    let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
    let descriptor = Darwin.open(
      canonicalRoot.path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      throw WorkspaceFileSystemError.invalidRoot
    }
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else {
      Darwin.close(descriptor)
      throw WorkspaceFileSystemError.invalidRoot
    }
    rootURL = canonicalRoot
    rootDescriptor = descriptor
    rootDevice = UInt64(status.st_dev)
    rootInode = UInt64(status.st_ino)
    self.configuration = configuration
    self.replacementPublicationHook = replacementPublicationHook
  }

  deinit {
    Darwin.close(rootDescriptor)
  }
}
