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

    var replacedStatus: stat?
    if let expectedRevision {
      let descriptor = try openRegularFileFromParent(named: name, parent: parentDescriptor)
      defer { Darwin.close(descriptor) }
      let existingData = try readData(
        from: descriptor, maximumBytes: configuration.maximumWriteBytes)
      guard revision(for: existingData) == expectedRevision else {
        throw WorkspaceFileSystemError.revisionConflict
      }
      var status = stat()
      guard fstat(descriptor, &status) == 0 else {
        throw WorkspaceFileSystemError.ioFailure
      }
      replacedStatus = status
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
      replacing: replacedStatus
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
    var count = 0
    var searchStart = current.content.startIndex
    while searchStart < current.content.endIndex,
      let range = current.content.range(
        of: oldText,
        range: searchStart..<current.content.endIndex
      )
    {
      count += 1
      guard count <= 10_000 else {
        throw WorkspaceFileSystemError.replacementCountMismatch
      }
      searchStart = range.upperBound
    }
    guard count == expectedOccurrences else {
      throw WorkspaceFileSystemError.replacementCountMismatch
    }
    let replacement = current.content.replacingOccurrences(of: oldText, with: newText)
    return try writeTextFile(
      replacement,
      at: path,
      expectedRevision: expectedRevision,
      relativeTo: workingDirectory
    )
  }

  private func openRegularFileFromParent(named name: String, parent: Int32) throws -> Int32 {
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
    guard openedStatus.st_nlink == 1 else {
      Darwin.close(descriptor)
      throw WorkspaceFileSystemError.hardLinkRejected
    }
    return descriptor
  }

  private func readData(from descriptor: Int32, maximumBytes: Int) throws -> Data {
    guard lseek(descriptor, 0, SEEK_SET) >= 0 else {
      throw WorkspaceFileSystemError.ioFailure
    }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      try Task.checkCancellation()
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
    replacing replacedStatus: stat?
  ) throws {
    let temporaryName = ".hex-write-\(UUID().uuidString.lowercased()).tmp"
    let descriptor = openat(
      parentDescriptor,
      temporaryName,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      mode_t(0o600)
    )
    guard descriptor >= 0 else {
      throw WorkspaceFileSystemError.ioFailure
    }
    var shouldRemoveTemporary = true
    defer {
      Darwin.close(descriptor)
      if shouldRemoveTemporary {
        _ = unlinkat(parentDescriptor, temporaryName, 0)
      }
    }

    if let replacedStatus {
      guard fchmod(descriptor, replacedStatus.st_mode & mode_t(0o777)) == 0 else {
        throw WorkspaceFileSystemError.ioFailure
      }
    }
    try writeAll(data, to: descriptor)
    guard fsync(descriptor) == 0 else {
      throw WorkspaceFileSystemError.ioFailure
    }
    try Task.checkCancellation()
    try validateDirectoryDescriptor(
      parentDescriptor,
      components: parentComponents
    )

    var publishedStatus = stat()
    guard fstat(descriptor, &publishedStatus) == 0 else {
      throw WorkspaceFileSystemError.ioFailure
    }

    if let replacedStatus {
      let currentStatus = try entryStatus(named: name, in: parentDescriptor)
      guard
        currentStatus.st_mode & S_IFMT == S_IFREG,
        currentStatus.st_dev == replacedStatus.st_dev,
        currentStatus.st_ino == replacedStatus.st_ino,
        currentStatus.st_size == replacedStatus.st_size,
        currentStatus.st_nlink == 1,
        currentStatus.st_mtimespec.tv_sec == replacedStatus.st_mtimespec.tv_sec,
        currentStatus.st_mtimespec.tv_nsec == replacedStatus.st_mtimespec.tv_nsec,
        currentStatus.st_ctimespec.tv_sec == replacedStatus.st_ctimespec.tv_sec,
        currentStatus.st_ctimespec.tv_nsec == replacedStatus.st_ctimespec.tv_nsec
      else {
        throw WorkspaceFileSystemError.revisionConflict
      }
      guard renameat(parentDescriptor, temporaryName, parentDescriptor, name) == 0 else {
        throw WorkspaceFileSystemError.ioFailure
      }
      shouldRemoveTemporary = false
    } else {
      guard linkat(parentDescriptor, temporaryName, parentDescriptor, name, 0) == 0 else {
        if errno == EEXIST {
          throw WorkspaceFileSystemError.destinationExists
        }
        throw WorkspaceFileSystemError.ioFailure
      }
      guard unlinkat(parentDescriptor, temporaryName, 0) == 0 else {
        throw WorkspaceFileSystemError.outcomeUncertain
      }
      shouldRemoveTemporary = false
    }
    guard fsync(parentDescriptor) == 0 else {
      throw WorkspaceFileSystemError.outcomeUncertain
    }
    do {
      try validateDirectoryDescriptor(
        parentDescriptor,
        components: parentComponents
      )
      let finalStatus = try entryStatus(named: name, in: parentDescriptor)
      guard
        finalStatus.st_mode & S_IFMT == S_IFREG,
        finalStatus.st_dev == publishedStatus.st_dev,
        finalStatus.st_ino == publishedStatus.st_ino,
        finalStatus.st_size == publishedStatus.st_size,
        finalStatus.st_nlink == 1
      else {
        throw WorkspaceFileSystemError.outcomeUncertain
      }
    } catch {
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
