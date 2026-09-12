import Darwin
import Foundation
import HexCore

/// Immutable descriptor ownership. The store actor serializes use; flock also coordinates separate
/// store instances/processes. Every operation rechecks the pathname against the pinned directory.
final class FileArtifactDirectory: Sendable {
  // Foundation may spell even a resolved /private/var URL as /var again. Keep the verified spelling
  // as a String so later identity checks never accidentally reintroduce that system symlink.
  let canonicalPath: String
  let descriptor: Int32
  let lockDescriptor: Int32

  init(url: URL) throws {
    guard url.isFileURL, url.user == nil, url.password == nil,
      url.path.hasPrefix("/"), url.path != "/",
      !url.path.contains("\0"), url.path.utf8.count <= 4_096
    else { throw ArtifactStoreError.invalidRequest }
    let path = try Self.canonicalRootPath(url.path)
    let root = try Self.openDirectory(path, create: true)
    do {
      let lock = Darwin.openat(
        root, ".artifact-lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
        mode_t(0o600))
      guard lock >= 0 else { throw ArtifactStoreError.unavailable }
      do {
        _ = try FileArtifactIO.status(lock, mode: 0o600)
      } catch {
        Darwin.close(lock)
        throw error
      }
      canonicalPath = path
      descriptor = root
      lockDescriptor = lock
    } catch {
      Darwin.close(root)
      throw error
    }
  }

  deinit {
    Darwin.close(lockDescriptor)
    Darwin.close(descriptor)
  }

  func withLock<T>(_ operation: () throws -> T) throws -> T {
    try validateIdentity()
    while flock(lockDescriptor, LOCK_EX) != 0 {
      guard errno == EINTR else { throw ArtifactStoreError.unavailable }
    }
    defer { _ = flock(lockDescriptor, LOCK_UN) }
    try validateIdentity()
    let result = try operation()
    try validateIdentity()
    return result
  }

  func synchronize() throws {
    guard Darwin.fsync(descriptor) == 0 else { throw ArtifactStoreError.unavailable }
  }

  private func validateIdentity() throws {
    let current = try Self.openDirectory(canonicalPath, create: false)
    defer { Darwin.close(current) }
    var pinned = stat()
    var named = stat()
    guard fstat(descriptor, &pinned) == 0, fstat(current, &named) == 0,
      FileArtifactIO.sameIdentity(pinned, named)
    else { throw ArtifactStoreError.corrupt }
    let lockStatus = try FileArtifactIO.status(lockDescriptor, mode: 0o600)
    guard fstatat(descriptor, ".artifact-lock", &named, AT_SYMLINK_NOFOLLOW) == 0,
      FileArtifactIO.sameIdentity(lockStatus, named), lockStatus.st_size == 0
    else { throw ArtifactStoreError.corrupt }
  }

  /// macOS deliberately exposes these root-owned aliases. Resolve only that exact OS prefix, then
  /// continue refusing arbitrary symlink ancestors/final roots. realpath's string is kept outside
  /// Foundation standardization; replacing or retargeting a system alias fails closed.
  private static func canonicalRootPath(_ path: String) throws -> String {
    let components = path.split(separator: "/").map(String.init)
    guard !components.isEmpty, !components.contains("."), !components.contains("..") else {
      throw ArtifactStoreError.invalidRequest
    }
    guard let first = components.first, ["var", "tmp", "etc"].contains(first) else {
      return "/" + components.joined(separator: "/")
    }
    let alias = "/" + first
    var status = stat()
    guard lstat(alias, &status) == 0, status.st_uid == 0 else {
      throw ArtifactStoreError.corrupt
    }
    if status.st_mode & S_IFMT != S_IFLNK {
      guard status.st_mode & S_IFMT == S_IFDIR else { throw ArtifactStoreError.corrupt }
      return "/" + components.joined(separator: "/")
    }
    guard let resolved = alias.withCString({ Darwin.realpath($0, nil) }) else {
      throw ArtifactStoreError.unavailable
    }
    defer { free(resolved) }
    let expected = "/private/" + first
    guard String(cString: resolved) == expected else { throw ArtifactStoreError.corrupt }
    return ([expected] + components.dropFirst()).joined(separator: "/")
  }

  /// Walk the canonical components with openat/O_NOFOLLOW. Only missing components are created;
  /// existing directory permissions are never broadened or changed.
  private static func openDirectory(_ path: String, create: Bool) throws -> Int32 {
    var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard current >= 0 else { throw ArtifactStoreError.unavailable }
    do {
      for component in path.split(separator: "/").map(String.init) {
        var next = Darwin.openat(
          current, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        if next < 0, errno == ENOENT, create {
          guard mkdirat(current, component, mode_t(0o700)) == 0 || errno == EEXIST else {
            throw ArtifactStoreError.unavailable
          }
          guard Darwin.fsync(current) == 0 else { throw ArtifactStoreError.unavailable }
          next = Darwin.openat(
            current, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard next >= 0 else { throw ArtifactStoreError.unavailable }
        Darwin.close(current)
        current = next
      }
      var status = stat()
      guard fstat(current, &status) == 0,
        status.st_mode & S_IFMT == S_IFDIR,
        status.st_uid == geteuid(), status.st_mode & 0o7777 == 0o700
      else { throw ArtifactStoreError.corrupt }
      return current
    } catch {
      Darwin.close(current)
      throw error
    }
  }
}
