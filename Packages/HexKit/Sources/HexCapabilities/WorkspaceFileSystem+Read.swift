import CryptoKit
import Darwin
import Foundation

extension WorkspaceFileSystem {
  public func readTextFile(
    at path: String,
    relativeTo workingDirectory: URL?
  ) throws -> WorkspaceTextFile {
    try Task.checkCancellation()
    let components = try combinedComponents(path: path, workingDirectory: workingDirectory)
    let data = try readData(components: components, maximumBytes: configuration.maximumReadBytes)
    guard let content = String(data: data, encoding: .utf8) else {
      throw WorkspaceFileSystemError.invalidUTF8
    }
    return WorkspaceTextFile(
      path: displayPath(components),
      content: content,
      revision: revision(for: data),
      byteCount: data.count
    )
  }

  public func listDirectory(
    at path: String,
    relativeTo workingDirectory: URL?
  ) throws -> [WorkspaceDirectoryEntry] {
    try Task.checkCancellation()
    let components = try combinedComponents(path: path, workingDirectory: workingDirectory)
    return try directoryEntries(components: components)
  }

  func readData(components: [String], maximumBytes: Int) throws -> Data {
    let descriptor = try openRegularFile(components: components)
    defer { Darwin.close(descriptor) }
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_size >= 0 else {
      throw WorkspaceFileSystemError.ioFailure
    }
    guard status.st_size <= maximumBytes else {
      throw WorkspaceFileSystemError.fileTooLarge
    }

    var data = Data()
    data.reserveCapacity(Int(status.st_size))
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      try Task.checkCancellation()
      let bytesRead = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
      }
      if bytesRead == 0 {
        break
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
    return data
  }

  func directoryEntries(components: [String]) throws -> [WorkspaceDirectoryEntry] {
    let descriptor = try openDirectory(components: components)
    guard let directory = fdopendir(descriptor) else {
      Darwin.close(descriptor)
      throw WorkspaceFileSystemError.ioFailure
    }
    defer { closedir(directory) }

    var entries: [WorkspaceDirectoryEntry] = []
    var resultBytes = 0
    while true {
      try Task.checkCancellation()
      errno = 0
      guard let rawEntry = readdir(directory) else {
        guard errno == 0 else {
          throw WorkspaceFileSystemError.ioFailure
        }
        break
      }
      let name = withUnsafePointer(to: &rawEntry.pointee.d_name) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
          String(validatingCString: $0)
        }
      }
      guard let name else {
        throw WorkspaceFileSystemError.ioFailure
      }
      guard name != ".", name != ".." else {
        continue
      }
      guard entries.count < configuration.maximumDirectoryEntries else {
        throw WorkspaceFileSystemError.capacityExceeded
      }
      let entryComponents = components + [name]
      do {
        try validateComponents(entryComponents, error: .invalidPath)
      } catch {
        throw WorkspaceFileSystemError.capacityExceeded
      }
      let path = displayPath(entryComponents)
      let (entryBytes, entryOverflowed) = path.utf8.count.addingReportingOverflow(
        name.utf8.count + 128
      )
      let (candidateResultBytes, resultOverflowed) = resultBytes.addingReportingOverflow(
        entryBytes
      )
      guard
        !entryOverflowed,
        !resultOverflowed,
        candidateResultBytes <= configuration.maximumDirectoryResultBytes
      else {
        throw WorkspaceFileSystemError.capacityExceeded
      }
      resultBytes = candidateResultBytes
      let status = try entryStatus(named: name, in: dirfd(directory))
      let kind: WorkspaceEntryKind
      let byteCount: Int?
      switch status.st_mode & S_IFMT {
      case S_IFREG:
        kind = .file
        byteCount = status.st_size >= 0 ? Int(exactly: status.st_size) : nil
      case S_IFDIR:
        kind = .directory
        byteCount = nil
      case S_IFLNK:
        kind = .symbolicLink
        byteCount = nil
      default:
        kind = .other
        byteCount = nil
      }
      entries.append(
        WorkspaceDirectoryEntry(
          path: path,
          name: name,
          kind: kind,
          byteCount: byteCount
        )
      )
    }
    entries.sort { $0.name < $1.name }
    return entries
  }

  func revision(for data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
