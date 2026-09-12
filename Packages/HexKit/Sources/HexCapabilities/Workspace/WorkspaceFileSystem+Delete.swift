import Darwin
import Foundation

extension WorkspaceFileSystem {
  public func deleteTextFile(
    at path: String, expectedRevision: String,
    relativeTo workingDirectory: URL?
  ) throws -> WorkspaceDeletionResult {
    guard WorkspaceRevision.isValid(expectedRevision) else {
      throw WorkspaceFileSystemError.invalidRevision
    }
    let components = try combinedComponents(path: path, workingDirectory: workingDirectory)
    guard let name = components.last else { throw WorkspaceFileSystemError.invalidPath }
    let parents = Array(components.dropLast())
    let parent = try openDirectory(components: parents)
    defer { Darwin.close(parent) }
    return try writeTransactionNamespace.withExclusiveWriteAccess(targetDescriptor: parent) {
      let existing = try fileSnapshot(
        named: name, in: parent, expectedLinkCount: 1, maximumBytes: configuration.maximumReadBytes)
      guard revision(for: existing.data) == expectedRevision else {
        throw WorkspaceFileSystemError.revisionConflict
      }
      let transaction = try WorkspaceWriteTransaction(namespace: writeTransactionNamespace)
      defer { transaction.close() }
      var moved = false
      defer {
        if !moved { _ = unlinkat(transaction.directoryDescriptor, transaction.candidateName, 0) }
      }
      try validateDirectoryDescriptor(parent, components: parents)
      try replacementPostValidationHook?()
      try Task.checkCancellation()
      // Move into a reserved same-volume namespace without replacing anything. The original inode
      // is retained, even on success, for recovery. Never unlink a raced public pathname.
      guard unlinkat(transaction.directoryDescriptor, transaction.candidateName, 0) == 0,
        renameatx_np(
          parent, name, transaction.directoryDescriptor, transaction.candidateName,
          UInt32(RENAME_EXCL)) == 0
      else { throw WorkspaceFileSystemError.ioFailure }
      moved = true
      let tombstone = transaction.directoryURL.appendingPathComponent(transaction.candidateName)
        .path
      do {
        let displaced = try fileSnapshot(
          named: transaction.candidateName, in: transaction.directoryDescriptor,
          expectedLinkCount: 1, maximumBytes: configuration.maximumReadBytes,
          checksCancellation: false)
        guard displaced.metadata.matches(existing.metadata, comparesChangeTime: false),
          revision(for: displaced.data) == expectedRevision,
          fsync(parent) == 0, fsync(transaction.directoryDescriptor) == 0
        else {
          throw WorkspaceFileSystemError.outcomeUncertain
        }
        try validateDirectoryDescriptor(parent, components: parents)
        var status = stat()
        guard fstatat(parent, name, &status, AT_SYMLINK_NOFOLLOW) < 0, errno == ENOENT else {
          throw WorkspaceFileSystemError.outcomeUncertain
        }
        return WorkspaceDeletionResult(tombstone: tombstone, confirmed: true)
      } catch { return WorkspaceDeletionResult(tombstone: tombstone, confirmed: false) }
    }
  }
}
