import Darwin
import Foundation

extension WorkspaceFileSystem {
  public func writeTextFile(
    _ content: String,
    at path: String,
    expectedRevision: String?,
    relativeTo workingDirectory: URL?
  ) throws -> WorkspaceTextFile {
    try Task.checkCancellation()
    let data = Data(content.utf8)
    guard data.count <= configuration.maximumWriteBytes, !content.contains("\0") else {
      throw WorkspaceFileSystemError.fileTooLarge
    }
    if let expectedRevision {
      guard WorkspaceRevision.isValid(expectedRevision) else {
        throw WorkspaceFileSystemError.invalidRevision
      }
    }
    let components = try combinedComponents(path: path, workingDirectory: workingDirectory)
    guard let name = components.last else {
      throw WorkspaceFileSystemError.invalidPath
    }
    let parentDescriptor = try openDirectory(components: Array(components.dropLast()))
    defer { Darwin.close(parentDescriptor) }

    var replacedMetadata: WorkspaceFileMetadataSnapshot?
    if let expectedRevision {
      let existing = try fileSnapshot(
        named: name,
        in: parentDescriptor,
        expectedLinkCount: 1,
        maximumBytes: configuration.maximumWriteBytes
      )
      guard
        revision(for: existing.data) == expectedRevision
      else {
        throw WorkspaceFileSystemError.revisionConflict
      }
      replacedMetadata = existing.metadata
      guard replacedMetadata?.permitsAtomicReplacement == true else {
        throw WorkspaceFileSystemError.ioFailure
      }
    } else {
      var status = stat()
      if fstatat(parentDescriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 {
        if status.st_mode & S_IFMT == S_IFLNK {
          throw WorkspaceFileSystemError.symbolicLinkRejected
        }
        throw WorkspaceFileSystemError.destinationExists
      }
      guard errno == ENOENT else {
        throw WorkspaceFileSystemError.ioFailure
      }
    }

    try commit(
      data,
      named: name,
      in: parentDescriptor,
      parentComponents: Array(components.dropLast()),
      replacing: replacedMetadata,
      expectedRevision: expectedRevision
    )
    return WorkspaceTextFile(
      path: displayPath(components),
      content: content,
      revision: revision(for: data),
      byteCount: data.count
    )
  }

  public func replaceText(
    _ oldText: String,
    with newText: String,
    in path: String,
    expectedRevision: String,
    expectedOccurrences: Int,
    relativeTo workingDirectory: URL?
  ) throws -> WorkspaceTextFile {
    guard
      !oldText.isEmpty,
      oldText.utf8.count <= configuration.maximumWriteBytes,
      newText.utf8.count <= configuration.maximumWriteBytes,
      (1...10_000).contains(expectedOccurrences)
    else {
      throw WorkspaceFileSystemError.replacementCountMismatch
    }
    let current = try readTextFile(at: path, relativeTo: workingDirectory)
    guard current.revision == expectedRevision else {
      throw WorkspaceFileSystemError.revisionConflict
    }
    let replacement = try BoundedTextReplacement.build(
      source: current.content,
      replacing: oldText,
      with: newText,
      expectedOccurrences: expectedOccurrences,
      maximumBytes: configuration.maximumWriteBytes
    )
    return try writeTextFile(
      replacement,
      at: path,
      expectedRevision: expectedRevision,
      relativeTo: workingDirectory
    )
  }

  private func openRegularFileFromParent(named name: String, parent: Int32) throws -> Int32 {
    try openRegularFileFromParentAllowingLinkCount(
      named: name,
      parent: parent,
      expectedLinkCount: 1
    )
  }

  private func openRegularFileFromParentAllowingLinkCount(
    named name: String,
    parent: Int32,
    expectedLinkCount: nlink_t
  ) throws -> Int32 {
    let status = try entryStatus(named: name, in: parent)
    guard status.st_mode & S_IFMT != S_IFLNK else {
      throw WorkspaceFileSystemError.symbolicLinkRejected
    }
    guard status.st_mode & S_IFMT == S_IFREG else {
      throw WorkspaceFileSystemError.notRegularFile
    }
    let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
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
    guard openedStatus.st_nlink == expectedLinkCount else {
      Darwin.close(descriptor)
      throw WorkspaceFileSystemError.hardLinkRejected
    }
    return descriptor
  }

  private func metadataSnapshot(
    named name: String,
    in parent: Int32,
    expectedLinkCount: nlink_t
  ) throws -> WorkspaceFileMetadataSnapshot {
    let descriptor = try openRegularFileFromParentAllowingLinkCount(
      named: name,
      parent: parent,
      expectedLinkCount: expectedLinkCount
    )
    defer { Darwin.close(descriptor) }
    return try WorkspaceFileMetadataSnapshot(descriptor: descriptor)
  }

  private func fileSnapshot(
    named name: String,
    in parent: Int32,
    expectedLinkCount: nlink_t,
    maximumBytes: Int,
    checksCancellation: Bool = true
  ) throws -> (metadata: WorkspaceFileMetadataSnapshot, data: Data) {
    let descriptor = try openRegularFileFromParentAllowingLinkCount(
      named: name,
      parent: parent,
      expectedLinkCount: expectedLinkCount
    )
    defer { Darwin.close(descriptor) }
    let metadataBeforeRead = try WorkspaceFileMetadataSnapshot(descriptor: descriptor)
    let data = try readData(
      from: descriptor,
      maximumBytes: maximumBytes,
      checksCancellation: checksCancellation
    )
    let metadataAfterRead = try WorkspaceFileMetadataSnapshot(descriptor: descriptor)
    guard
      metadataAfterRead.matches(
        metadataBeforeRead,
        comparesChangeTime: true
      ),
      metadataAfterRead.size == data.count
    else {
      throw WorkspaceFileSystemError.revisionConflict
    }
    return (metadataAfterRead, data)
  }

  private func readData(
    from descriptor: Int32,
    maximumBytes: Int,
    checksCancellation: Bool
  ) throws -> Data {
    guard lseek(descriptor, 0, SEEK_SET) >= 0 else {
      throw WorkspaceFileSystemError.ioFailure
    }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      if checksCancellation {
        try Task.checkCancellation()
      }
      let bytesRead = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
      }
      if bytesRead == 0 {
        return data
      }
      if bytesRead < 0 {
        if errno == EINTR {
          continue
        }
        throw WorkspaceFileSystemError.ioFailure
      }
      let (candidateCount, overflowed) = data.count.addingReportingOverflow(bytesRead)
      guard !overflowed, candidateCount <= maximumBytes else {
        throw WorkspaceFileSystemError.fileTooLarge
      }
      data.append(buffer, count: bytesRead)
    }
  }

  private func commit(
    _ data: Data,
    named name: String,
    in parentDescriptor: Int32,
    parentComponents: [String],
    replacing replacedMetadata: WorkspaceFileMetadataSnapshot?,
    expectedRevision: String?
  ) throws {
    try writeTransactionNamespace.withExclusiveWriteAccess(
      targetDescriptor: parentDescriptor
    ) {
      try commitWithExclusiveNamespace(
        data,
        named: name,
        in: parentDescriptor,
        parentComponents: parentComponents,
        replacing: replacedMetadata,
        expectedRevision: expectedRevision
      )
    }
  }

  private func commitWithExclusiveNamespace(
    _ data: Data,
    named name: String,
    in parentDescriptor: Int32,
    parentComponents: [String],
    replacing replacedMetadata: WorkspaceFileMetadataSnapshot?,
    expectedRevision: String?
  ) throws {
    let transaction = try WorkspaceWriteTransaction(
      namespace: writeTransactionNamespace
    )
    let temporaryName = transaction.candidateName
    let descriptor = transaction.candidateDescriptor
    var shouldRemoveTemporary = true
    defer {
      if shouldRemoveTemporary {
        _ = unlinkat(transaction.directoryDescriptor, temporaryName, 0)
      }
      transaction.close()
    }

    try writeAll(data, to: descriptor)
    if let replacedMetadata {
      try replacedMetadata.applyPreservedMetadata(to: descriptor)
    }
    guard fsync(descriptor) == 0 else {
      throw WorkspaceFileSystemError.ioFailure
    }
    try Task.checkCancellation()
    try validateDirectoryDescriptor(
      parentDescriptor,
      components: parentComponents
    )

    let publishedMetadata = try WorkspaceFileMetadataSnapshot(descriptor: descriptor)

    if let replacedMetadata {
      let currentMetadata = try metadataSnapshot(
        named: name,
        in: parentDescriptor,
        expectedLinkCount: 1
      )
      guard
        currentMetadata.matches(
          replacedMetadata,
          comparesChangeTime: true
        )
      else {
        throw WorkspaceFileSystemError.revisionConflict
      }
      try replacementPublicationHook?()
      let postPublicationHookMetadata = try metadataSnapshot(
        named: name,
        in: parentDescriptor,
        expectedLinkCount: 1
      )
      guard
        postPublicationHookMetadata.matches(
          replacedMetadata,
          comparesChangeTime: true
        )
      else {
        throw WorkspaceFileSystemError.revisionConflict
      }
      try replacementPostValidationHook?()
      let postValidationHookMetadata = try metadataSnapshot(
        named: name,
        in: parentDescriptor,
        expectedLinkCount: 1
      )
      guard
        postValidationHookMetadata.matches(
          replacedMetadata,
          comparesChangeTime: true
        )
      else {
        throw WorkspaceFileSystemError.revisionConflict
      }
      try Task.checkCancellation()
      guard
        renameatx_np(
          transaction.directoryDescriptor,
          temporaryName,
          parentDescriptor,
          name,
          UInt32(RENAME_SWAP)
        ) == 0
      else {
        if errno == ENOENT {
          throw WorkspaceFileSystemError.revisionConflict
        }
        throw WorkspaceFileSystemError.ioFailure
      }
      shouldRemoveTemporary = false

      let displacedMetadata: WorkspaceFileMetadataSnapshot
      do {
        displacedMetadata = try metadataSnapshot(
          named: temporaryName,
          in: transaction.directoryDescriptor,
          expectedLinkCount: 1
        )
      } catch {
        throw WorkspaceFileSystemError.outcomeUncertain
      }
      do {
        try replacementPostSwapHook?()
        try validateDirectoryDescriptor(
          parentDescriptor,
          components: parentComponents
        )
        try validatePublishedReplacement(
          named: name,
          temporaryName: temporaryName,
          in: parentDescriptor,
          transactionDescriptor: transaction.directoryDescriptor,
          expectedMetadata: replacedMetadata,
          expectedRevision: expectedRevision,
          publishedMetadata: publishedMetadata,
          publishedData: data
        )
        guard fsync(parentDescriptor) == 0 else {
          throw WorkspaceFileSystemError.outcomeUncertain
        }
        try validateDirectoryDescriptor(
          parentDescriptor,
          components: parentComponents
        )
        try validatePublishedReplacement(
          named: name,
          temporaryName: temporaryName,
          in: parentDescriptor,
          transactionDescriptor: transaction.directoryDescriptor,
          expectedMetadata: replacedMetadata,
          expectedRevision: expectedRevision,
          publishedMetadata: publishedMetadata,
          publishedData: data
        )
      } catch let validationError {
        do {
          try restoreRejectedReplacement(
            named: name,
            temporaryName: temporaryName,
            in: parentDescriptor,
            transactionDescriptor: transaction.directoryDescriptor,
            displacedMetadata: displacedMetadata,
            publishedMetadata: publishedMetadata,
            publishedData: data,
            expectedRevision: expectedRevision,
            transactionURL: transaction.directoryURL
          )
          shouldRemoveTemporary = false
          try finishWriteTransaction(transaction)
        } catch {
          throw WorkspaceFileSystemError.outcomeUncertain
        }
        throw validationError
      }
      guard unlinkat(transaction.directoryDescriptor, temporaryName, 0) == 0 else {
        throw WorkspaceFileSystemError.outcomeUncertain
      }
      shouldRemoveTemporary = false
    } else {
      try creationPublicationHook?()
      try Task.checkCancellation()
      guard
        linkat(
          transaction.directoryDescriptor,
          temporaryName,
          parentDescriptor,
          name,
          0
        ) == 0
      else {
        if errno == EEXIST {
          throw WorkspaceFileSystemError.destinationExists
        }
        throw WorkspaceFileSystemError.ioFailure
      }
      shouldRemoveTemporary = false
      do {
        try creationPostLinkHook?()
        try validateDirectoryDescriptor(
          parentDescriptor,
          components: parentComponents
        )
        try validatePublishedCreation(
          named: name,
          in: parentDescriptor,
          publishedMetadata: publishedMetadata,
          publishedData: data
        )
        guard fsync(parentDescriptor) == 0 else {
          throw WorkspaceFileSystemError.outcomeUncertain
        }
        try validateDirectoryDescriptor(
          parentDescriptor,
          components: parentComponents
        )
        try validatePublishedCreation(
          named: name,
          in: parentDescriptor,
          publishedMetadata: publishedMetadata,
          publishedData: data
        )
      } catch let validationError {
        do {
          try removeRejectedCreation(
            named: name,
            temporaryName: temporaryName,
            in: parentDescriptor,
            transactionDescriptor: transaction.directoryDescriptor,
            publishedMetadata: publishedMetadata,
            publishedData: data
          )
          try finishWriteTransaction(transaction)
        } catch {
          throw WorkspaceFileSystemError.outcomeUncertain
        }
        throw validationError
      }
      guard unlinkat(transaction.directoryDescriptor, temporaryName, 0) == 0 else {
        throw WorkspaceFileSystemError.outcomeUncertain
      }
      shouldRemoveTemporary = false
    }
    do {
      try finishWriteTransaction(transaction)
    } catch {
      throw WorkspaceFileSystemError.outcomeUncertain
    }
  }

  private func finishWriteTransaction(
    _ transaction: WorkspaceWriteTransaction
  ) throws {
    try transactionPreTeardownHook?(transaction.directoryURL)
    guard
      fsync(transaction.directoryDescriptor) == 0
    else {
      throw WorkspaceFileSystemError.outcomeUncertain
    }
    try writeTransactionNamespace.validateDescriptor()
  }

  private func validatePublishedReplacement(
    named name: String,
    temporaryName: String,
    in parentDescriptor: Int32,
    transactionDescriptor: Int32,
    expectedMetadata: WorkspaceFileMetadataSnapshot,
    expectedRevision: String?,
    publishedMetadata: WorkspaceFileMetadataSnapshot,
    publishedData: Data
  ) throws {
    guard let expectedRevision else {
      throw WorkspaceFileSystemError.revisionConflict
    }
    let currentPublished = try fileSnapshot(
      named: name,
      in: parentDescriptor,
      expectedLinkCount: 1,
      maximumBytes: configuration.maximumWriteBytes
    )
    guard
      currentPublished.metadata.matches(
        publishedMetadata,
        comparesChangeTime: false
      ),
      currentPublished.data == publishedData
    else {
      throw WorkspaceFileSystemError.revisionConflict
    }

    let displaced = try fileSnapshot(
      named: temporaryName,
      in: transactionDescriptor,
      expectedLinkCount: 1,
      maximumBytes: configuration.maximumWriteBytes
    )
    guard
      displaced.metadata.matches(
        expectedMetadata,
        comparesChangeTime: false
      ),
      revision(for: displaced.data) == expectedRevision
    else {
      throw WorkspaceFileSystemError.revisionConflict
    }
  }

  private func validatePublishedCreation(
    named name: String,
    in parentDescriptor: Int32,
    publishedMetadata: WorkspaceFileMetadataSnapshot,
    publishedData: Data
  ) throws {
    let current = try fileSnapshot(
      named: name,
      in: parentDescriptor,
      expectedLinkCount: 2,
      maximumBytes: configuration.maximumWriteBytes
    )
    guard
      current.metadata.matches(
        publishedMetadata,
        comparesChangeTime: false,
        expectedLinkCount: 2
      ),
      current.data == publishedData
    else {
      throw WorkspaceFileSystemError.revisionConflict
    }
  }

  private func removeRejectedCreation(
    named name: String,
    temporaryName: String,
    in parentDescriptor: Int32,
    transactionDescriptor: Int32,
    publishedMetadata: WorkspaceFileMetadataSnapshot,
    publishedData: Data
  ) throws {
    let rejectedName = try moveRejectedCreationToUniqueName(
      named: name,
      in: parentDescriptor,
      transactionDescriptor: transactionDescriptor
    )

    do {
      let rejected = try fileSnapshot(
        named: rejectedName,
        in: transactionDescriptor,
        expectedLinkCount: 2,
        maximumBytes: configuration.maximumWriteBytes,
        checksCancellation: false
      )
      guard
        rejected.metadata.matches(
          publishedMetadata,
          comparesChangeTime: false,
          expectedLinkCount: 2
        ),
        rejected.data == publishedData
      else {
        throw WorkspaceFileSystemError.revisionConflict
      }
    } catch {
      guard
        renameatx_np(
          transactionDescriptor,
          rejectedName,
          parentDescriptor,
          name,
          UInt32(RENAME_EXCL)
        ) == 0
      else {
        throw WorkspaceFileSystemError.outcomeUncertain
      }
      let candidate = try fileSnapshot(
        named: temporaryName,
        in: transactionDescriptor,
        expectedLinkCount: 1,
        maximumBytes: configuration.maximumWriteBytes,
        checksCancellation: false
      )
      guard
        candidate.metadata.matches(
          publishedMetadata,
          comparesChangeTime: false
        ),
        candidate.data == publishedData,
        unlinkat(transactionDescriptor, temporaryName, 0) == 0,
        fsync(transactionDescriptor) == 0,
        fsync(parentDescriptor) == 0
      else {
        throw WorkspaceFileSystemError.outcomeUncertain
      }
      return
    }

    guard
      unlinkat(transactionDescriptor, rejectedName, 0) == 0,
      unlinkat(transactionDescriptor, temporaryName, 0) == 0,
      fsync(transactionDescriptor) == 0,
      fsync(parentDescriptor) == 0
    else {
      throw WorkspaceFileSystemError.outcomeUncertain
    }
  }

  private func moveRejectedCreationToUniqueName(
    named name: String,
    in parentDescriptor: Int32,
    transactionDescriptor: Int32
  ) throws -> String {
    for _ in 0..<16 {
      let rejectedName = WorkspaceWriteTransaction.uniqueName(prefix: "rejected-publication")
      if renameatx_np(
        parentDescriptor,
        name,
        transactionDescriptor,
        rejectedName,
        UInt32(RENAME_EXCL)
      ) == 0 {
        return rejectedName
      }
      guard errno == EEXIST else {
        throw WorkspaceFileSystemError.outcomeUncertain
      }
    }
    throw WorkspaceFileSystemError.capacityExceeded
  }

  private func restoreRejectedReplacement(
    named name: String,
    temporaryName: String,
    in parentDescriptor: Int32,
    transactionDescriptor: Int32,
    displacedMetadata: WorkspaceFileMetadataSnapshot,
    publishedMetadata: WorkspaceFileMetadataSnapshot,
    publishedData: Data,
    expectedRevision: String?,
    transactionURL: URL
  ) throws {
    guard let expectedRevision else {
      throw WorkspaceFileSystemError.outcomeUncertain
    }
    let currentPublished = try fileSnapshot(
      named: name,
      in: parentDescriptor,
      expectedLinkCount: 1,
      maximumBytes: configuration.maximumWriteBytes,
      checksCancellation: false
    )
    let currentDisplaced = try fileSnapshot(
      named: temporaryName,
      in: transactionDescriptor,
      expectedLinkCount: 1,
      maximumBytes: configuration.maximumWriteBytes,
      checksCancellation: false
    )
    guard
      currentPublished.metadata.matches(
        publishedMetadata,
        comparesChangeTime: false
      ),
      currentPublished.data == publishedData,
      currentDisplaced.metadata.matches(
        displacedMetadata,
        comparesChangeTime: false
      ),
      revision(for: currentDisplaced.data) == expectedRevision
    else {
      throw WorkspaceFileSystemError.outcomeUncertain
    }
    try replacementPreRollbackSwapHook?(transactionURL)
    guard
      renameatx_np(
        transactionDescriptor,
        temporaryName,
        parentDescriptor,
        name,
        UInt32(RENAME_SWAP)
      ) == 0
    else {
      throw WorkspaceFileSystemError.outcomeUncertain
    }

    do {
      let restored = try fileSnapshot(
        named: name,
        in: parentDescriptor,
        expectedLinkCount: 1,
        maximumBytes: configuration.maximumWriteBytes,
        checksCancellation: false
      )
      let rejected = try fileSnapshot(
        named: temporaryName,
        in: transactionDescriptor,
        expectedLinkCount: 1,
        maximumBytes: configuration.maximumWriteBytes,
        checksCancellation: false
      )
      guard
        restored.metadata.matches(
          displacedMetadata,
          comparesChangeTime: false
        ),
        revision(for: restored.data) == expectedRevision,
        rejected.metadata.matches(
          publishedMetadata,
          comparesChangeTime: false
        ),
        rejected.data == publishedData
      else {
        throw WorkspaceFileSystemError.outcomeUncertain
      }
    } catch {
      _ = renameatx_np(
        transactionDescriptor,
        temporaryName,
        parentDescriptor,
        name,
        UInt32(RENAME_SWAP)
      )
      _ = fsync(transactionDescriptor)
      _ = fsync(parentDescriptor)
      throw WorkspaceFileSystemError.outcomeUncertain
    }

    guard
      unlinkat(transactionDescriptor, temporaryName, 0) == 0,
      fsync(transactionDescriptor) == 0,
      fsync(parentDescriptor) == 0
    else {
      throw WorkspaceFileSystemError.outcomeUncertain
    }
  }

  private func validateDirectoryDescriptor(
    _ descriptor: Int32,
    components: [String]
  ) throws {
    let currentDescriptor = try openDirectory(components: components)
    defer { Darwin.close(currentDescriptor) }
    var expectedStatus = stat()
    var currentStatus = stat()
    guard
      fstat(descriptor, &expectedStatus) == 0,
      fstat(currentDescriptor, &currentStatus) == 0,
      expectedStatus.st_mode & S_IFMT == S_IFDIR,
      currentStatus.st_mode & S_IFMT == S_IFDIR,
      expectedStatus.st_dev == currentStatus.st_dev,
      expectedStatus.st_ino == currentStatus.st_ino
    else {
      throw WorkspaceFileSystemError.revisionConflict
    }
  }

  private func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        try Task.checkCancellation()
        let written = Darwin.write(
          descriptor,
          bytes.baseAddress?.advanced(by: offset),
          bytes.count - offset
        )
        if written < 0 {
          if errno == EINTR {
            continue
          }
          throw WorkspaceFileSystemError.ioFailure
        }
        guard written > 0 else {
          throw WorkspaceFileSystemError.ioFailure
        }
        offset += written
      }
    }
  }

}
