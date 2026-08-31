import Darwin
import Foundation

final class MCPExecutableSnapshot: Sendable {
  static let maximumExecutableBytes: off_t = 256 * 1_024 * 1_024

  let executablePath: String
  let status: stat

  private let directoryPath: String
  private let directoryDescriptor: Int32
  private let executableDescriptor: Int32

  private init(
    executablePath: String,
    status: stat,
    directoryPath: String,
    directoryDescriptor: Int32,
    executableDescriptor: Int32
  ) {
    self.executablePath = executablePath
    self.status = status
    self.directoryPath = directoryPath
    self.directoryDescriptor = directoryDescriptor
    self.executableDescriptor = executableDescriptor
  }

  deinit {
    Darwin.close(executableDescriptor)
    "executable".withCString { name in
      _ = unlinkat(directoryDescriptor, name, 0)
    }
    Darwin.close(directoryDescriptor)
    _ = Darwin.rmdir(directoryPath)
  }

  static func create(
    from sourceDescriptor: Int32,
    initialStatus: stat,
    afterSourceValidation: (@Sendable (_ snapshotPath: String) -> Void)?
  ) throws -> MCPExecutableSnapshot {
    guard isAcceptableSource(initialStatus) else {
      throw MCPClientSessionError.connectionClosed
    }

    var template = Array("/private/tmp/.hex-mcp-executable.XXXXXX".utf8CString)
    guard mkdtemp(&template) != nil else {
      throw MCPClientSessionError.connectionClosed
    }
    let directoryPath = String(
      decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
      as: UTF8.self
    )
    var directoryDescriptor = Int32(-1)
    var executableDescriptor = Int32(-1)
    var completed = false
    defer {
      if !completed {
        if executableDescriptor >= 0 { Darwin.close(executableDescriptor) }
        if directoryDescriptor >= 0 {
          "executable".withCString { name in
            _ = unlinkat(directoryDescriptor, name, 0)
          }
          Darwin.close(directoryDescriptor)
        }
        _ = Darwin.rmdir(directoryPath)
      }
    }

    directoryDescriptor = Darwin.open(
      directoryPath,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard directoryDescriptor >= 0, fchmod(directoryDescriptor, 0o700) == 0 else {
      throw MCPClientSessionError.connectionClosed
    }
    var directoryStatus = stat()
    guard
      fstat(directoryDescriptor, &directoryStatus) == 0,
      directoryStatus.st_mode & S_IFMT == S_IFDIR,
      directoryStatus.st_uid == geteuid(),
      directoryStatus.st_mode & 0o077 == 0
    else {
      throw MCPClientSessionError.connectionClosed
    }

    executableDescriptor = "executable".withCString { name in
      openat(
        directoryDescriptor,
        name,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
        0o500
      )
    }
    guard executableDescriptor >= 0 else {
      throw MCPClientSessionError.connectionClosed
    }

    afterSourceValidation?(directoryPath + "/executable")
    try copyExactBytes(
      from: sourceDescriptor,
      to: executableDescriptor,
      expectedByteCount: initialStatus.st_size
    )

    var finalSourceStatus = stat()
    guard
      fstat(sourceDescriptor, &finalSourceStatus) == 0,
      sameSourceIdentityAndMetadata(initialStatus, finalSourceStatus),
      fchmod(executableDescriptor, 0o500) == 0,
      fsync(executableDescriptor) == 0
    else {
      throw MCPClientSessionError.connectionClosed
    }

    var snapshotStatus = stat()
    guard
      fstat(executableDescriptor, &snapshotStatus) == 0,
      snapshotStatus.st_mode & S_IFMT == S_IFREG,
      snapshotStatus.st_uid == geteuid(),
      snapshotStatus.st_nlink == 1,
      snapshotStatus.st_size == initialStatus.st_size,
      snapshotStatus.st_mode & 0o777 == 0o500
    else {
      throw MCPClientSessionError.connectionClosed
    }

    completed = true
    return MCPExecutableSnapshot(
      executablePath: directoryPath + "/executable",
      status: snapshotStatus,
      directoryPath: directoryPath,
      directoryDescriptor: directoryDescriptor,
      executableDescriptor: executableDescriptor
    )
  }

  func isIntact() -> Bool {
    var descriptorStatus = stat()
    var pathStatus = stat()
    let pathResult = executablePath.withCString { path in
      lstat(path, &pathStatus)
    }
    return fstat(executableDescriptor, &descriptorStatus) == 0
      && pathResult == 0
      && Self.sameSnapshotIdentityAndMetadata(status, descriptorStatus)
      && Self.sameSnapshotIdentityAndMetadata(status, pathStatus)
  }

  static func isAcceptableSource(_ status: stat) -> Bool {
    let effectiveUserID = geteuid()
    return status.st_mode & S_IFMT == S_IFREG
      && (status.st_uid == 0 || status.st_uid == effectiveUserID)
      && status.st_nlink == 1
      && status.st_size > 0
      && status.st_size <= maximumExecutableBytes
      && hasExecutionPermission(status, effectiveUserID: effectiveUserID)
      && status.st_mode & (S_ISUID | S_ISGID) == 0
      && status.st_mode & (S_IWGRP | S_IWOTH) == 0
  }

  private static func hasExecutionPermission(
    _ status: stat,
    effectiveUserID: uid_t
  ) -> Bool {
    if status.st_uid == effectiveUserID {
      return status.st_mode & S_IXUSR != 0
    }
    if effectiveUserID == 0 {
      return status.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0
    }
    return status.st_mode & S_IXOTH != 0
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
      try writeAll(
        buffer: buffer,
        count: count,
        descriptor: destinationDescriptor
      )
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

  private static func sameSourceIdentityAndMetadata(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev
      && lhs.st_ino == rhs.st_ino
      && lhs.st_mode == rhs.st_mode
      && lhs.st_nlink == rhs.st_nlink
      && lhs.st_uid == rhs.st_uid
      && lhs.st_gid == rhs.st_gid
      && lhs.st_size == rhs.st_size
      && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
      && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
      && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
      && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
  }

  private static func sameSnapshotIdentityAndMetadata(_ lhs: stat, _ rhs: stat) -> Bool {
    sameSourceIdentityAndMetadata(lhs, rhs)
  }
}
