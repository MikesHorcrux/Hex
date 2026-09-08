import Darwin
import Foundation

/// Shares the old JSON writer's transaction lock until the one-time SQLite import commits.
final class SQLiteHeartbeatLegacyImportLock {
  private let descriptor: Int32?

  init(fileURL: URL) throws {
    var source = stat()
    guard lstat(fileURL.path, &source) == 0 else {
      if errno == ENOENT {
        descriptor = nil
        return
      }
      throw SQLiteHexHeartbeatStoreError.unavailable
    }
    let path = fileURL.appendingPathExtension("lock").path
    let descriptor = Darwin.open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw SQLiteHexHeartbeatStoreError.unavailable }
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
      status.st_uid == geteuid(), status.st_nlink == 1
    else {
      Darwin.close(descriptor)
      throw SQLiteHexHeartbeatStoreError.unavailable
    }
    while flock(descriptor, LOCK_EX) != 0 {
      if errno != EINTR {
        Darwin.close(descriptor)
        throw SQLiteHexHeartbeatStoreError.unavailable
      }
    }
    self.descriptor = descriptor
  }

  deinit {
    if let descriptor {
      _ = flock(descriptor, LOCK_UN)
      Darwin.close(descriptor)
    }
  }
}
