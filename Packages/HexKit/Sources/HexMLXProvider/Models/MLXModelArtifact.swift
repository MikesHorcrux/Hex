import Darwin
import HexProviders

struct MLXModelArtifact {
  let name: String
  let fileDescriptor: Int32
  let device: UInt64
  let inode: UInt64
  let owner: uid_t
  let group: gid_t
  let permissions: mode_t
  let size: UInt64
  let modifiedSeconds: Int
  let modifiedNanoseconds: Int
  let changedSeconds: Int
  let changedNanoseconds: Int

  init(name: String, fileDescriptor: Int32, status: stat) throws {
    let permissions = status.st_mode & mode_t(0o7777)
    guard
      status.st_mode & S_IFMT == S_IFREG,
      status.st_size > 0,
      status.st_uid == geteuid(),
      permissions & mode_t(0o022) == 0,
      UInt64(status.st_nlink) == 1
    else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }
    self.name = name
    self.fileDescriptor = fileDescriptor
    device = UInt64(status.st_dev)
    inode = UInt64(status.st_ino)
    owner = status.st_uid
    group = status.st_gid
    self.permissions = permissions
    size = UInt64(status.st_size)
    modifiedSeconds = status.st_mtimespec.tv_sec
    modifiedNanoseconds = status.st_mtimespec.tv_nsec
    changedSeconds = status.st_ctimespec.tv_sec
    changedNanoseconds = status.st_ctimespec.tv_nsec
  }

  func matches(_ status: stat) -> Bool {
    let permissions = status.st_mode & mode_t(0o7777)
    return status.st_mode & S_IFMT == S_IFREG
      && status.st_size >= 0
      && UInt64(status.st_dev) == device
      && UInt64(status.st_ino) == inode
      && status.st_uid == owner
      && owner == geteuid()
      && status.st_gid == group
      && permissions == self.permissions
      && UInt64(status.st_nlink) == 1
      && UInt64(status.st_size) == size
      && status.st_mtimespec.tv_sec == modifiedSeconds
      && status.st_mtimespec.tv_nsec == modifiedNanoseconds
      && status.st_ctimespec.tv_sec == changedSeconds
      && status.st_ctimespec.tv_nsec == changedNanoseconds
  }
}
