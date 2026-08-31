import Darwin
import Foundation

struct WorkspaceWriteTransaction {
  static let candidateName = "candidate"
  static let rejectedPublicationName = "rejected-publication"

  let directoryURL: URL
  let directoryDescriptor: Int32

  init(appropriateFor targetURL: URL, targetDescriptor: Int32) throws {
    let directoryURL: URL
    do {
      directoryURL = try FileManager().url(
        for: .itemReplacementDirectory,
        in: .userDomainMask,
        appropriateFor: targetURL,
        create: true
      )
    } catch {
      throw WorkspaceFileSystemError.ioFailure
    }

    let descriptor = Darwin.open(
      directoryURL.path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      throw WorkspaceFileSystemError.outcomeUncertain
    }

    var descriptorStatus = stat()
    var namedStatus = stat()
    var targetStatus = stat()
    guard
      fstat(descriptor, &descriptorStatus) == 0,
      lstat(directoryURL.path, &namedStatus) == 0,
      fstat(targetDescriptor, &targetStatus) == 0,
      descriptorStatus.st_mode & S_IFMT == S_IFDIR,
      descriptorStatus.st_dev == namedStatus.st_dev,
      descriptorStatus.st_ino == namedStatus.st_ino,
      descriptorStatus.st_dev == targetStatus.st_dev,
      descriptorStatus.st_uid == geteuid(),
      Self.removeInheritedAccessControlList(from: descriptor),
      fchflags(descriptor, 0) == 0,
      fchmod(descriptor, mode_t(0o700)) == 0,
      fstat(descriptor, &descriptorStatus) == 0,
      descriptorStatus.st_mode & mode_t(0o7777) == mode_t(0o700),
      descriptorStatus.st_flags == 0
    else {
      Darwin.close(descriptor)
      throw WorkspaceFileSystemError.outcomeUncertain
    }

    self.directoryURL = directoryURL
    directoryDescriptor = descriptor
  }

  func close() {
    Darwin.close(directoryDescriptor)
  }

  private static func removeInheritedAccessControlList(from descriptor: Int32) -> Bool {
    guard let accessControlList = acl_init(1) else {
      return false
    }
    defer { _ = acl_free(UnsafeMutableRawPointer(accessControlList)) }
    return acl_set_fd_np(descriptor, accessControlList, ACL_TYPE_EXTENDED) == 0
  }
}
