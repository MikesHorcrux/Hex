import Darwin
import Foundation

public actor WorkspaceFileSystem {
  let rootURL: URL
  let rootDescriptor: Int32
  let rootDevice: UInt64
  let rootInode: UInt64
  let configuration: WorkspaceFileSystemConfiguration
  let writeTransactionNamespace: WorkspaceWriteTransactionNamespace
  let replacementPublicationHook: (@Sendable () throws -> Void)?
  let replacementPostValidationHook: (@Sendable () throws -> Void)?
  let replacementPostSwapHook: (@Sendable () throws -> Void)?
  let replacementPreRollbackSwapHook: (@Sendable (URL) throws -> Void)?
  let transactionPreTeardownHook: (@Sendable (URL) throws -> Void)?
  let creationPublicationHook: (@Sendable () throws -> Void)?
  let creationPostLinkHook: (@Sendable () throws -> Void)?
  let readDataPreflightHook: (@Sendable (Int) -> Void)?

  public init(
    root: URL,
    configuration: WorkspaceFileSystemConfiguration = .standard,
    writeTransactionNamespace: WorkspaceWriteTransactionNamespace? = nil
  ) throws {
    try self.init(
      root: root,
      configuration: configuration,
      replacementPublicationHook: nil,
      replacementPostValidationHook: nil,
      replacementPostSwapHook: nil,
      replacementPreRollbackSwapHook: nil,
      transactionPreTeardownHook: nil,
      creationPublicationHook: nil,
      creationPostLinkHook: nil,
      readDataPreflightHook: nil,
      writeTransactionNamespace: writeTransactionNamespace
    )
  }

  init(
    root: URL,
    configuration: WorkspaceFileSystemConfiguration = .standard,
    replacementPublicationHook: (@Sendable () throws -> Void)?,
    replacementPostValidationHook: (@Sendable () throws -> Void)? = nil,
    replacementPostSwapHook: (@Sendable () throws -> Void)? = nil,
    replacementPreRollbackSwapHook: (@Sendable (URL) throws -> Void)? = nil,
    transactionPreTeardownHook: (@Sendable (URL) throws -> Void)? = nil,
    creationPublicationHook: (@Sendable () throws -> Void)? = nil,
    creationPostLinkHook: (@Sendable () throws -> Void)? = nil,
    readDataPreflightHook: (@Sendable (Int) -> Void)? = nil,
    writeTransactionNamespace: WorkspaceWriteTransactionNamespace? = nil
  ) throws {
    guard root.isFileURL, root.path.hasPrefix("/"), !root.path.contains("\0") else {
      throw WorkspaceFileSystemError.invalidRoot
    }
    let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
    guard WorkspacePathScalarPolicy.isPromptSafe(canonicalRoot.path) else {
      throw WorkspaceFileSystemError.invalidRoot
    }
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
    let namespace: WorkspaceWriteTransactionNamespace
    do {
      if let writeTransactionNamespace {
        namespace = writeTransactionNamespace
      } else {
        namespace = try WorkspaceWriteTransactionNamespace(
          appropriateFor: canonicalRoot,
          targetDescriptor: descriptor
        )
      }
      try namespace.withExclusiveWriteAccess(targetDescriptor: descriptor) {}
    } catch {
      Darwin.close(descriptor)
      throw error
    }
    rootURL = canonicalRoot
    rootDescriptor = descriptor
    rootDevice = UInt64(status.st_dev)
    rootInode = UInt64(status.st_ino)
    self.configuration = configuration
    self.writeTransactionNamespace = namespace
    self.replacementPublicationHook = replacementPublicationHook
    self.replacementPostValidationHook = replacementPostValidationHook
    self.replacementPostSwapHook = replacementPostSwapHook
    self.replacementPreRollbackSwapHook = replacementPreRollbackSwapHook
    self.transactionPreTeardownHook = transactionPreTeardownHook
    self.creationPublicationHook = creationPublicationHook
    self.creationPostLinkHook = creationPostLinkHook
    self.readDataPreflightHook = readDataPreflightHook
  }

  deinit {
    Darwin.close(rootDescriptor)
  }
}
