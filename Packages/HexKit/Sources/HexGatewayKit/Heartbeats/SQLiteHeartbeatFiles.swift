import Darwin
import Foundation

/// Pins owned directory/database inodes. SQLite gets a regular private file, never a symlink or
/// hard-link alias. Standard macOS /var aliases are resolved by the kernel, not rejected as roots.
final class SQLiteHeartbeatFiles {
  let path: String
  private let directoryPath: String
  private let directoryFD: Int32
  private let databaseFD: Int32
  private let databaseName: String

  init(databaseURL: URL) throws {
    guard databaseURL.isFileURL else { throw SQLiteHexHeartbeatStoreError.unavailable }
    let parent = databaseURL.deletingLastPathComponent()
    let name = databaseURL.lastPathComponent
    guard parent.path != "/", !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
      throw SQLiteHexHeartbeatStoreError.unavailable
    }
    var parentStatus = stat()
    if lstat(parent.path, &parentStatus) != 0 {
      guard errno == ENOENT else { throw SQLiteHexHeartbeatStoreError.unavailable }
      try FileManager.default.createDirectory(
        at: parent, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      guard lstat(parent.path, &parentStatus) == 0 else {
        throw SQLiteHexHeartbeatStoreError.unavailable
      }
    }
    guard parentStatus.st_mode & S_IFMT == S_IFDIR, parentStatus.st_uid == geteuid() else {
      throw SQLiteHexHeartbeatStoreError.unavailable
    }
    let directoryFD = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard directoryFD >= 0 else { throw SQLiteHexHeartbeatStoreError.unavailable }
    var directoryOwned = true
    defer { if directoryOwned { Darwin.close(directoryFD) } }
    var pinned = stat()
    guard fstat(directoryFD, &pinned) == 0, Self.same(parentStatus, pinned),
      fchmod(directoryFD, S_IRWXU) == 0,
      let canonical = realpath(parent.path, nil)
    else { throw SQLiteHexHeartbeatStoreError.unavailable }
    let canonicalPath = String(cString: canonical)
    free(canonical)
    let databaseFD = Darwin.openat(
      directoryFD, name, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard databaseFD >= 0 else { throw SQLiteHexHeartbeatStoreError.unavailable }
    var databaseOwned = true
    defer { if databaseOwned { Darwin.close(databaseFD) } }
    var fileStatus = stat()
    guard fstat(databaseFD, &fileStatus) == 0, Self.isOwnedFile(fileStatus),
      fchmod(databaseFD, S_IRUSR | S_IWUSR) == 0,
      fsync(directoryFD) == 0
    else { throw SQLiteHexHeartbeatStoreError.unavailable }
    self.directoryFD = directoryFD
    self.databaseFD = databaseFD
    directoryPath = canonicalPath
    databaseName = name
    path = canonicalPath + "/" + name
    directoryOwned = false
    databaseOwned = false
    try validate()
  }

  deinit {
    Darwin.close(databaseFD)
    Darwin.close(directoryFD)
  }

  func validate() throws {
    var directoryPathStatus = stat()
    var directoryPinned = stat()
    var pathStatus = stat()
    var filePinned = stat()
    guard lstat(directoryPath, &directoryPathStatus) == 0,
      fstat(directoryFD, &directoryPinned) == 0,
      Self.same(directoryPathStatus, directoryPinned),
      directoryPathStatus.st_mode & S_IFMT == S_IFDIR,
      directoryPathStatus.st_uid == geteuid(), directoryPathStatus.st_mode & 0o077 == 0,
      fstatat(directoryFD, databaseName, &pathStatus, AT_SYMLINK_NOFOLLOW) == 0,
      fstat(databaseFD, &filePinned) == 0, Self.same(pathStatus, filePinned),
      Self.isOwnedFile(pathStatus),
      pathStatus.st_mode & 0o077 == 0
    else { throw SQLiteHexHeartbeatStoreError.unavailable }
    for suffix in ["-journal", "-wal", "-shm"] {
      var status = stat()
      if fstatat(directoryFD, databaseName + suffix, &status, AT_SYMLINK_NOFOLLOW) == 0 {
        guard Self.isOwnedFile(status), status.st_mode & 0o077 == 0 else {
          throw SQLiteHexHeartbeatStoreError.unavailable
        }
      } else if errno != ENOENT {
        throw SQLiteHexHeartbeatStoreError.unavailable
      }
    }
  }

  private static func same(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
  }
  private static func isOwnedFile(_ status: stat) -> Bool {
    status.st_mode & S_IFMT == S_IFREG && status.st_uid == geteuid() && status.st_nlink == 1
  }
}
